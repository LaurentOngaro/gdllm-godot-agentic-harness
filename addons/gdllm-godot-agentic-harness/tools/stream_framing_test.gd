extends SceneTree
## Headless regression tests for the streaming chat path's HTTP body framings, over a real local socket.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/stream_framing_test.gd
## Exits nonzero on any failure.
##
## What these guard: a streamed reply legally arrives in any of three body framings — Content-Length, chunked, or nothing at all, delimited by the connection's end (koboldcpp's built-in server streams the unframed shape under an explicit keep-alive). All three must stream to completion through the same poll loop, with line endings in either CRLF or bare-LF form: the unframed case runs through a deliberate mid-generation silence, pinning that prompt-processing time is never time-boxed. The decode pipeline must hold across arbitrary byte boundaries — a UTF-8 codepoint split between writes, a final line the close leaves unterminated — since transport drains land wherever TCP cut them, not on the server's line boundaries. And the failure paths must keep their attribution: an error status reports its body even when its unframed stream never closes (idle time caps that wait), a close before any response blames the server, and undeclarable framing is named as not-HTTP rather than waited on.

const Client = preload("res://addons/gdllm-godot-agentic-harness/llm_client.gd")

const SSE_CHUNKS: PackedStringArray = [
	'data: {"choices":[{"delta":{"content":"hello"},"index":0}]}\n\n',
	'data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}]}\n\n',
	"data: [DONE]\n\n",
]
const UTF8_LINE := 'data: {"choices":[{"delta":{"content":"🎈"},"index":0}]}\n\n' ## The split-decode case's payload; its 4-byte emoji is where the write boundary lands.
const BODY_DELAY := 1.2 ## Seconds the streaming cases sit silent between headers and body — the prompt-processing pause that must never trip a timeout.

## Each case: how the mock server frames (or refuses) its response, and what the client must resolve to. `timeout` widens the wait for the case that must ride out the idle grace.
const CASES: Array = [
	{"name": "unframed keep-alive (koboldcpp shape) streams", "frame": "eof", "want_ok": true},
	{"name": "chunked (llama.cpp shape) streams", "frame": "chunked", "want_ok": true},
	{"name": "content-length streams", "frame": "length", "want_ok": true},
	{"name": "LF-only header block streams", "frame": "eof_lf", "want_ok": true},
	{"name": "a final line the close leaves unterminated still finishes clean", "frame": "eof_nonl", "want_ok": true},
	{"name": "a UTF-8 codepoint split across writes decodes whole", "frame": "eof_utf8", "want_ok": true, "want_text": "🎈"},
	{"name": "an error status quotes its body", "frame": "error", "want_ok": false, "want_contains": ["HTTP 400", "model not found"]},
	{"name": "an unframed error reply on a held-open socket still reports", "frame": "stall_error", "want_ok": false, "want_contains": ["HTTP 503", "overloaded"], "timeout": 25.0},
	{"name": "garbage Content-Length fails as not-HTTP", "frame": "bad_length", "want_ok": false, "want_contains": ["isn't HTTP"]},
	{"name": "a close before any reply blames the server", "frame": "slam", "want_ok": false, "want_contains": ["closed the connection before replying"]},
	{"name": "a mid-upload rejection reports the server's reason", "frame": "early_reject", "want_ok": false, "want_contains": ["HTTP 413", "request too large"], "big_payload": true},
]

var _checks: int = 0
var _failures: int = 0

var _case: int = -1
var _server: TCPServer
var _peer: StreamPeerTCP
var _client: Client
var _request_bytes: String = ""
var _headers_sent: bool = false
var _body_stage: int = 0 ## How many of the case's body writes have gone out (the split-decode case sends two).
var _outcome: String = "" ## "" until the client resolves; then "failed: <reason>" or "ok: <reply>", with " [truncated]" appended when the stats carried the flag.
var _elapsed: float = 0.0
var _done: bool = false


func _init() -> void:
	_start_next_case()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: " + what)


## Bring up a fresh listener + client pair for the next case and fire the chat request at it.
func _start_next_case() -> void:
	_case += 1
	if _case >= CASES.size():
		if _failures == 0:
			print("OK: %d checks, 0 failures" % _checks)
		else:
			printerr("FAILED: %d of %d checks" % [_failures, _checks])
		_done = true
		quit(1 if _failures > 0 else 0)
		return
	_request_bytes = ""
	_headers_sent = false
	_body_stage = 0
	_outcome = ""
	_elapsed = 0.0
	_peer = null
	_server = TCPServer.new()
	var err := _server.listen(0, "127.0.0.1")
	assert(err == OK)
	_client = Client.new()
	_client.api_base = "http://127.0.0.1:%d" % _server.get_local_port()
	_client.adapter_kind = "openai"
	_client.model = "test-model"
	root.add_child(_client)
	_client.request_failed.connect(func(reason: String) -> void: _outcome = "failed: " + reason)
	_client.response_received.connect(func(text: String, stats: Dictionary) -> void:
		_outcome = "ok: " + text + (" [truncated]" if bool(stats.get("truncated", false)) else ""))
	# The mid-upload case needs a POST too big to fit the loopback buffers, so the client is demonstrably still SENDING when the rejection arrives.
	var content := "x".repeat(16_000_000) if bool(CASES[_case].get("big_payload", false)) else "hi"
	_client.send_chat_request([{"role": "user", "content": content}])


func _finish_case() -> void:
	var case: Dictionary = CASES[_case]
	_client.queue_free()
	_server.stop()
	if _outcome == "timeout":
		pass # the timeout _check already booked the failure; judging "timeout" against the case's wants would double-count it
	elif bool(case["want_ok"]):
		var want := "ok: " + String(case.get("want_text", "hello")) # no [truncated] suffix: every ok case must finish CLEAN
		_check(_outcome == want, "%s (want: %s, got: %s)" % [case["name"], want, _outcome])
	else:
		_check(_outcome.begins_with("failed: "), "%s resolves as a failure (got: %s)" % [case["name"], _outcome])
		for needle in case.get("want_contains", []):
			_check(_outcome.contains(String(needle)), "%s: the failure carries \"%s\" (got: %s)" % [case["name"], needle, _outcome])
	_start_next_case()


## Serve one request the way the case's server would: swallow the POST, answer per the case's framing — the streaming cases send headers at once but hold the body back for BODY_DELAY, as a server still processing the prompt does.
func _serve() -> void:
	if _peer == null and _server.is_connection_available():
		_peer = _server.take_connection()
	if _peer == null:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var frame := String(CASES[_case]["frame"])
	if frame == "early_reject":
		# The rejecting server never reads the request at all: the 413 goes out the moment the connection lands, the socket stays open (a close with the upload unread would RST the response away), and the client must pick the answer up while its own upload is still stuck.
		if not _headers_sent:
			_headers_sent = true
			var reject := '{"error": "request too large"}'
			_peer.put_data(("HTTP/1.1 413 Content Too Large\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s" % [reject.length(), reject]).to_utf8_buffer())
		return
	var avail := _peer.get_available_bytes()
	if avail > 0:
		_request_bytes += _peer.get_utf8_string(avail)
	if not _request_bytes.contains("\r\n\r\n"):
		return
	var head := _request_bytes.get_slice("\r\n\r\n", 0)
	var body_len := 0
	for line in head.split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			body_len = int(line.get_slice(":", 1))
	if _request_bytes.length() < head.length() + 4 + body_len:
		return # POST body still arriving
	if frame == "slam":
		# Only after the whole POST is in: a close mid-upload would (rightly) read as broke-mid-request, a different failure than the one under test.
		_peer.disconnect_from_host()
		return
	if not _headers_sent:
		_headers_sent = true
		_send_headers(frame)
		return
	_send_body(frame)


## The case's response header block (plus, for the cases whose point is the header itself, the body in the same write).
func _send_headers(frame: String) -> void:
	match frame:
		"eof", "eof_nonl", "eof_utf8":
			# koboldcpp's exact response shape: HTTP/1.1, explicit keep-alive, no length, no chunking.
			_peer.put_data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n".to_utf8_buffer())
		"eof_lf":
			_peer.put_data("HTTP/1.1 200 OK\nContent-Type: text/event-stream\nConnection: keep-alive\n\n".to_utf8_buffer())
		"chunked":
			_peer.put_data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".to_utf8_buffer())
		"length":
			var whole := "".join(SSE_CHUNKS)
			_peer.put_data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: %d\r\n\r\n" % whole.to_utf8_buffer().size()).to_utf8_buffer())
		"error":
			var err_body := '{"error": {"message": "model not found"}}'
			_peer.put_data(("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s" % [err_body.length(), err_body]).to_utf8_buffer())
			_body_stage = 99
		"stall_error":
			# The un-endable error: a status body on an unframed keep-alive stream that never closes. The client's idle grace, not this socket, must end the wait.
			_peer.put_data('HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: keep-alive\r\n\r\n{"error": "overloaded"}'.to_utf8_buffer())
			_body_stage = 99
		"bad_length":
			_peer.put_data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: banana\r\n\r\n".to_utf8_buffer())
			_body_stage = 99


## The case's body writes, once the prompt-processing pause has elapsed; stage 99 means the case has nothing (more) to send.
func _send_body(frame: String) -> void:
	if _body_stage >= 99 or _elapsed < BODY_DELAY:
		return
	match frame:
		"eof", "eof_lf":
			_peer.put_data("".join(SSE_CHUNKS).to_utf8_buffer())
			_peer.disconnect_from_host() # the connection's end IS this body's framing
		"eof_nonl":
			# The terminal marker as the unterminated final line — no finish_reason line before it, so ONLY a flush of the lineless tail can mark the reply finished rather than truncated.
			_peer.put_data((SSE_CHUNKS[0] + "data: [DONE]").to_utf8_buffer())
			_peer.disconnect_from_host()
		"eof_utf8":
			var whole := (UTF8_LINE + SSE_CHUNKS[1] + SSE_CHUNKS[2]).to_utf8_buffer()
			var split := 'data: {"choices":[{"delta":{"content":"'.to_utf8_buffer().size() + 2 # two bytes into the emoji's four
			if _body_stage == 0:
				_peer.put_data(whole.slice(0, split))
				_body_stage = 1
				return
			if _elapsed < BODY_DELAY + 0.3:
				return # hold the tail long enough that the client demonstrably drained the partial codepoint alone
			_peer.put_data(whole.slice(split))
			_peer.disconnect_from_host()
		"chunked":
			var out := ""
			for chunk in SSE_CHUNKS:
				out += "%x\r\n%s\r\n" % [chunk.length(), chunk]
			out += "0\r\n\r\n"
			_peer.put_data(out.to_utf8_buffer())
		"length":
			_peer.put_data("".join(SSE_CHUNKS).to_utf8_buffer())
	if _body_stage == 0:
		_body_stage = 99


func _process(delta: float) -> bool:
	if _done:
		return true
	_elapsed += delta
	_serve()
	if _outcome != "":
		_finish_case()
	elif _elapsed > float(CASES[_case].get("timeout", 10.0)):
		_check(false, "%s never resolved within its window" % String(CASES[_case]["name"]))
		_outcome = "timeout"
		_finish_case()
	return false
