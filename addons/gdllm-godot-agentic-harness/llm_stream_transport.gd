@tool
class_name LLMStreamTransport extends RefCounted
## One streamed HTTP POST over a socket this plugin owns end to end, replacing HTTPClient on the chat path. A streamed reply legally arrives in any of three body framings — Content-Length, chunked, or unframed (delimited by the connection's end; koboldcpp's built-in server streams this shape) — and HTTPClient reads only the first two, filing the third as an empty body before a byte of it is readable. Owning the header parse puts the framing decision where a client can make it honestly: read the response's own headers, then pick the matching reader. Everything here is non-blocking and driven by poll(), one instance per request; the caller reads decoded body bytes with read_chunk() and never sees the framing.
##
## Deliberately NOT here: redirects, compression, and 100-continue negotiation — this transport writes its own request side, so it never asks for any of them (no Accept-Encoding, no Expect), and a stray 1xx is skipped rather than negotiated. Non-streamed traffic (model lists, probes, completions) stays on HTTPRequest, which handles framed bodies fine.
##
## Line endings are CRLF per the RFC, with bare LF accepted everywhere a line ends — RFC 7230 tells recipients to tolerate it, and the minimal hand-rolled servers this transport exists for are exactly the ones that emit it.

enum State {
	IDLE, ## begin() not yet called.
	RESOLVING, ## Hostname in the async resolver queue.
	CONNECTING, ## TCP connect in flight.
	TLS_HANDSHAKE, ## Socket up, TLS handshaking.
	SENDING, ## Writing the request bytes; sent_bytes() exposes progress so the caller can time-box a stalled upload without punishing a slow-but-moving one.
	WAITING, ## Request written; awaiting the response's header block (the model's prompt-processing time lives here, so the caller must not time-box it).
	BODY, ## Headers parsed; body bytes decode through read_chunk() as they arrive.
	DONE, ## Body complete — by its framing's own end, by the socket closing first, or by a framing loss mid-body (the caller tells a finished reply from a truncated one by its wire format's terminal marker, not by this state).
	FAILED, ## Terminal failure; fail_kind says which, fail_detail carries any specifics.
}

enum Fail {
	NONE,
	RESOLVE, ## The hostname didn't resolve.
	CONNECT, ## Nothing accepted the TCP connection.
	TLS, ## The TLS handshake failed.
	CLOSED_BEFORE_REPLY, ## The socket closed before a response header block arrived.
	BROKE_MID_REQUEST, ## Writing the request failed partway.
	BAD_RESPONSE, ## What answered isn't parseable HTTP (status line, header block, or declared framing); fail_detail quotes the offending text. Never raised once body bytes are flowing — a framing loss mid-body lands in DONE with what decoded, since throwing away a partial reply over a framing hiccup punishes the user twice.
}

enum _Framing { LENGTH, CHUNKED, EOF }

const FAIL_DETAIL_CHARS := 200 ## How much offending text a BAD_RESPONSE quotes — enough for the caller's own excerpt cap (LLMClient.BODY_EXCERPT_CHARS) to work with, so pre-truncation here never becomes the binding limit there.
const HEADER_BLOCK_CAP := 32768 ## Most a response's header block may occupy before the wait is abandoned as not-HTTP. Real header blocks are under a few KB; without a cap, a non-HTTP service that streams forever without a blank line would grow _inbuf unboundedly while WAITING has (deliberately) no timeout.

var state: int = State.IDLE
var fail_kind: int = Fail.NONE
var fail_detail: String = ""
var response_code: int = 0 ## Valid once state reaches BODY; 0 before.
var response_headers: Dictionary = {} ## Lowercased header name -> value, once state reaches BODY.

var _host: String = ""
var _port: int = 0
var _tls_options: TLSOptions = null
var _resolve_id: int = -1
var _tcp: StreamPeerTCP
var _tls: StreamPeerTLS
var _peer: StreamPeer ## The stream requests and responses actually ride: _tls when encrypted, else _tcp.
var _request: PackedByteArray
var _sent: int = 0
var _inbuf: PackedByteArray = PackedByteArray() ## Raw bytes off the wire, not yet consumed by the header or body parser.
var _scan_from: int = 0 ## Where the header-terminator scan resumes in _inbuf; without it every WAITING frame would re-scan the whole buffer from 0 — O(n²) against a server that trickles.
var _decoded: PackedByteArray = PackedByteArray() ## Body bytes with the framing stripped, awaiting read_chunk().
var _framing: int = _Framing.EOF
var _body_left: int = 0 ## LENGTH framing: bytes of body still owed.
var _chunk_left: int = -1 ## CHUNKED framing: bytes left in the open chunk; -1 = awaiting a size line, -2 = awaiting the line ending that closes a finished chunk.
var _in_trailer: bool = false ## CHUNKED framing: past the terminal 0-chunk, discarding trailer lines until the blank one ends the body.
var _eof: bool = false ## The socket closed and its buffered bytes are drained; what ending that means depends on the state it lands in.


## Fire the whole request: resolve, connect, optionally handshake, write, then stream the response through poll(). `headers` carries the caller's lines (Content-Type, auth); Host, Content-Length, Connection: close, and Accept are appended here — close because each instance serves exactly one request, and saying so lets well-behaved servers end an EOF-framed body by actually closing. All failures, including immediate ones, surface through state/fail_kind on a later poll, so the caller has a single error path.
func begin(host: String, port: int, tls_options: TLSOptions, path: String, headers: PackedStringArray, body: String) -> void:
	assert(state == State.IDLE)
	_host = host
	_port = port
	_tls_options = tls_options
	var body_bytes := body.to_utf8_buffer()
	# The port rides the Host header only when it isn't the scheme's default, matching what every mainstream client sends.
	var default_port: bool = (port == 443) if tls_options != null else (port == 80)
	var head := "POST %s HTTP/1.1\r\nHost: %s\r\n" % [path, host if default_port else "%s:%d" % [host, port]]
	for h in headers:
		head += h + "\r\n"
	head += "Content-Length: " + str(body_bytes.size()) + "\r\nConnection: close\r\nAccept: */*\r\n\r\n"
	_request = head.to_utf8_buffer()
	_request.append_array(body_bytes)
	if _host.is_valid_ip_address():
		_start_connect(_host)
		return
	_resolve_id = IP.resolve_hostname_queue_item(_host)
	if _resolve_id == IP.RESOLVER_INVALID_ID:
		_fail(Fail.RESOLVE)
	else:
		state = State.RESOLVING


## Decoded body bytes accumulated since the last call (drained on read). Meaningful from BODY on; keep calling in DONE to drain the tail.
func read_chunk() -> PackedByteArray:
	var out := _decoded
	_decoded = PackedByteArray()
	return out


## Request bytes written so far. The caller's stall watch compares this between frames: a moving upload is healthy however slow the link, a frozen one has a peer that stopped reading.
func sent_bytes() -> int:
	return _sent


## Drive whatever phase the request is in; call every frame until DONE or FAILED.
func poll() -> void:
	match state:
		State.RESOLVING:
			match IP.get_resolve_item_status(_resolve_id):
				IP.RESOLVER_STATUS_DONE:
					var ip := IP.get_resolve_item_address(_resolve_id)
					IP.erase_resolve_item(_resolve_id)
					_resolve_id = -1
					if ip == "":
						_fail(Fail.RESOLVE)
					else:
						_start_connect(ip)
				IP.RESOLVER_STATUS_WAITING:
					pass
				_:
					IP.erase_resolve_item(_resolve_id)
					_resolve_id = -1
					_fail(Fail.RESOLVE)
		State.CONNECTING:
			_tcp.poll()
			match _tcp.get_status():
				StreamPeerTCP.STATUS_CONNECTED:
					if _tls_options != null:
						_tls = StreamPeerTLS.new()
						# The hostname, not the resolved IP, is what the certificate must match.
						if _tls.connect_to_stream(_tcp, _host, _tls_options) != OK:
							_fail(Fail.TLS)
						else:
							state = State.TLS_HANDSHAKE
					else:
						_peer = _tcp
						state = State.SENDING
				StreamPeerTCP.STATUS_CONNECTING:
					pass
				_:
					_fail(Fail.CONNECT)
		State.TLS_HANDSHAKE:
			_tls.poll()
			match _tls.get_status():
				StreamPeerTLS.STATUS_CONNECTED:
					_peer = _tls
					state = State.SENDING
				StreamPeerTLS.STATUS_HANDSHAKING:
					pass
				_:
					_fail(Fail.TLS)
		State.SENDING:
			# The receive side pumps during the upload too: a server can reject mid-upload (auth, a payload over its limit) by answering without ever draining the request, and its response — the actual explanation — outranks the rest of an upload it has refused to read.
			_pump()
			_try_parse_headers()
			if state != State.SENDING:
				return
			var res: Array = _peer.put_partial_data(_request.slice(_sent))
			if int(res[0]) != OK:
				# The peer stopped taking bytes. A graceful early rejection leaves its response readable right up to the close (only a hard reset destroys it), so one more pump-and-parse tells "the server answered why" from a bare transport break.
				_pump()
				_try_parse_headers()
				if state == State.SENDING:
					_fail(Fail.BROKE_MID_REQUEST, error_string(int(res[0])))
				return
			_sent += int(res[1])
			if _sent >= _request.size():
				_request = PackedByteArray() # nothing left to send; don't hold the payload alive for the stream's whole life
				state = State.WAITING
				poll() # the response may already be buffered (a fast local server); parse it this frame rather than next
		State.WAITING:
			_pump()
			_try_parse_headers()
			if state == State.WAITING:
				if _eof:
					_fail(Fail.CLOSED_BEFORE_REPLY)
				elif _inbuf.size() > HEADER_BLOCK_CAP:
					_fail(Fail.BAD_RESPONSE, _inbuf.slice(0, FAIL_DETAIL_CHARS).get_string_from_utf8())
		State.BODY:
			_pump()
			_consume_body()
		_:
			pass


## Release everything: a pending resolver slot, the TLS stream, the socket. Safe to call in any state, including after failure.
func close() -> void:
	if _resolve_id != -1:
		IP.erase_resolve_item(_resolve_id)
		_resolve_id = -1
	if _tls != null:
		_tls.disconnect_from_stream()
		_tls = null
	if _tcp != null:
		_tcp.disconnect_from_host()
		_tcp = null
	_peer = null


func _start_connect(ip: String) -> void:
	_tcp = StreamPeerTCP.new()
	if _tcp.connect_to_host(ip, _port) != OK:
		_fail(Fail.CONNECT)
	else:
		state = State.CONNECTING


func _fail(kind: int, detail: String = "") -> void:
	fail_kind = kind
	fail_detail = detail.left(FAIL_DETAIL_CHARS)
	state = State.FAILED


## Move whatever the socket has onto _inbuf, and note its closure as _eof. Reads only happen while the peer reports open — a closed peer's get_available_bytes is an engine error, not a zero — and no bytes are lost to that ordering: StreamPeerTCP only reports closed once a peek finds the receive buffer empty AND the FIN behind it, so "not open" already means "drained".
func _pump() -> void:
	if _tls != null:
		_tls.poll()
	if _tcp != null:
		_tcp.poll()
	if _peer == null:
		return
	var open: bool
	if _peer == _tls:
		open = _tls.get_status() == StreamPeerTLS.STATUS_CONNECTED or _tls.get_status() == StreamPeerTLS.STATUS_HANDSHAKING
	else:
		open = _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED
	if not open:
		_eof = true
		return
	var avail := _peer.get_available_bytes()
	while avail > 0:
		var res: Array = _peer.get_partial_data(avail)
		if int(res[0]) != OK:
			break
		_inbuf.append_array(res[1])
		avail = _peer.get_available_bytes()


## Parse the response's header block out of _inbuf once its blank line has arrived, choose the body framing from what the headers actually declare, and enter BODY. Loops because an informational 1xx (which nothing here asked for) is a whole header block to skip before the real response.
func _try_parse_headers() -> void:
	while true:
		var term := _find_blank_line(_inbuf, maxi(0, _scan_from - 3))
		if term.is_empty():
			# Resume the next scan just before this one's tail, far enough back to catch a terminator split across arrivals.
			_scan_from = _inbuf.size()
			return
		var head := _inbuf.slice(0, int(term[0])).get_string_from_utf8()
		_inbuf = _inbuf.slice(int(term[0]) + int(term[1]))
		_scan_from = 0
		var lines := head.replace("\r\n", "\n").split("\n")
		# A mixed-endings block (CRLF lines, bare-LF blank line) leaves a stray \r on line tails; strip_edges clears it before any syntax judgment.
		var status_line := lines[0].strip_edges()
		var status_parts := status_line.split(" ", false)
		if not status_line.begins_with("HTTP/") or status_parts.size() < 2 or not status_parts[1].is_valid_int():
			_fail(Fail.BAD_RESPONSE, status_line)
			return
		var code := int(status_parts[1])
		if code >= 100 and code < 200:
			continue
		if code < 100:
			# "HTTP/1.1 000" and friends: syntactically a status line, semantically not one — and downstream a code of 0 means "no response yet".
			_fail(Fail.BAD_RESPONSE, status_line)
			return
		response_code = code
		for i in range(1, lines.size()):
			var colon := lines[i].find(":")
			if colon > 0:
				response_headers[lines[i].substr(0, colon).strip_edges().to_lower()] = lines[i].substr(colon + 1).strip_edges()
		if String(response_headers.get("transfer-encoding", "")).to_lower().contains("chunked"):
			_framing = _Framing.CHUNKED
			_chunk_left = -1
		elif response_headers.has("content-length"):
			var declared := String(response_headers["content-length"])
			if not declared.is_valid_int() or int(declared) < 0:
				# int() would read garbage as 0 and file the whole reply as already complete — the same honesty bar the chunk-size parse holds.
				_fail(Fail.BAD_RESPONSE, "Content-Length: " + declared)
				return
			_framing = _Framing.LENGTH
			_body_left = int(declared)
		else:
			# No framing declared: the body runs to the connection's end — the shape HTTPClient cannot read, and the reason this transport exists.
			_framing = _Framing.EOF
		state = State.BODY
		_request = PackedByteArray() # a response ends the upload wherever it stood; an early rejection's unsent tail has no reader and shouldn't sit in memory for the stream's life
		_consume_body() # body bytes often share the packet that completed the headers
		return


## Strip the response's framing from _inbuf onto _decoded and recognize the body's end. A socket that closes early still lands in DONE with whatever decoded — the caller's wire format knows whether the reply carried its terminal marker, and attributing truncation is its job, not a guess made here.
func _consume_body() -> void:
	match _framing:
		_Framing.EOF:
			if _inbuf.size() > 0:
				_decoded.append_array(_inbuf)
				_inbuf = PackedByteArray()
			if _eof:
				state = State.DONE
		_Framing.LENGTH:
			if _inbuf.size() > 0 and _body_left > 0:
				var n := mini(_body_left, _inbuf.size())
				_decoded.append_array(_inbuf.slice(0, n))
				_inbuf = _inbuf.slice(n)
				_body_left -= n
			if _body_left <= 0 or _eof:
				state = State.DONE
		_Framing.CHUNKED:
			_consume_chunked()


## The chunked reader works a local cursor over _inbuf and compacts once on exit — a fast local stream delivers many chunks per poll, and re-slicing the buffer per chunk would copy its tail once per chunk. A framing loss (unparseable size line, a chunk not closed by a line ending) ends the body as DONE rather than failing: bytes were already flowing, so the reply-so-far is worth more than the diagnosis, and the missing terminal marker discloses the cut to the caller.
func _consume_chunked() -> void:
	var pos := 0
	while true:
		if _in_trailer:
			var nl := _find_line_end(_inbuf, pos)
			if nl.is_empty():
				break
			var trailer := _inbuf.slice(pos, int(nl[0])).get_string_from_utf8()
			pos = int(nl[0]) + int(nl[1])
			if trailer.strip_edges() == "":
				state = State.DONE
				break
			continue # a trailer header; nothing here wants one
		if _chunk_left == -2:
			var nl := _find_line_end(_inbuf, pos)
			if nl.is_empty():
				break
			if int(nl[0]) != pos:
				# The chunk's declared length should land exactly on a line ending; bytes before it mean the framing is desynced.
				state = State.DONE
				break
			pos = int(nl[0]) + int(nl[1])
			_chunk_left = -1
			continue
		if _chunk_left == -1:
			var nl := _find_line_end(_inbuf, pos)
			if nl.is_empty():
				break
			# A size line may carry ";extensions"; only the hex count matters.
			var line := _inbuf.slice(pos, int(nl[0])).get_string_from_utf8().get_slice(";", 0).strip_edges()
			pos = int(nl[0]) + int(nl[1])
			if line == "":
				continue # tolerate a stray blank between chunks
			if not line.is_valid_hex_number():
				state = State.DONE
				break
			var size := line.hex_to_int()
			if size == 0:
				_in_trailer = true
			else:
				_chunk_left = size
			continue
		var have := _inbuf.size() - pos
		if have == 0:
			break
		var n := mini(_chunk_left, have)
		_decoded.append_array(_inbuf.slice(pos, pos + n))
		pos += n
		_chunk_left -= n
		if _chunk_left == 0:
			_chunk_left = -2
	if pos > 0:
		_inbuf = _inbuf.slice(pos)
	if _eof and state == State.BODY:
		state = State.DONE # the server quit mid-chunk; hand over what decoded and let the caller attribute the cut


## The first header-block terminator at or after `from`: [index, length] for CRLFCRLF or LFLF (whichever comes first), empty when none has arrived yet.
static func _find_blank_line(buf: PackedByteArray, from: int) -> Array:
	for i in range(from, buf.size() - 1):
		if buf[i] == 10 and buf[i + 1] == 10:
			return [i, 2]
		if i + 3 < buf.size() and buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return [i, 4]
	return []


## The first line ending at or after `from`: [index of its first byte, length] for CRLF or bare LF, empty when the line is still incomplete. The index points at the CR when one is present, so slicing to it never includes the terminator.
static func _find_line_end(buf: PackedByteArray, from: int) -> Array:
	for i in range(from, buf.size()):
		if buf[i] == 10:
			if i > from and buf[i - 1] == 13:
				return [i - 1, 2]
			return [i, 1]
	return []
