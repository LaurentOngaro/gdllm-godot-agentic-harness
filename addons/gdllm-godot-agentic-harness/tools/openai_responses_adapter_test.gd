extends SceneTree
## Headless regression tests for OpenAIResponsesAdapter: request-body translation (instructions lift, flat tools, input items, the reasoning effort/summary knob, function_call_output binding, the trailing-loop raw-item echo and its alien-blocks fallback for a mid-loop kind switch, the tool-less flatten), the semantic SSE stream reassembly (the wire-format progress guard, text and reasoning-summary deltas with part separators, function_call items, usage, refusal/incomplete/failed/error frames — proxy-shaped typeless ones included), the completion helpers, and the base normalization.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/openai_responses_adapter_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const LLMAdapters = preload("res://addons/gdllm-godot-agentic-harness/llm_adapters.gd")

## A minimal attached tool, so a test request carries a tools param — without one the adapter flattens tool turns to text (see _test_toolless_flatten).
const SOME_TOOLS: Array = [{"type": "function", "function": {"name": "read_file", "description": "Read a file.", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}}]

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_chat_body_basics()
	_test_effort_and_summary()
	_test_tool_translation()
	_test_input_translation()
	_test_trailing_loop_echo()
	_test_kind_switch_fallback()
	_test_toolless_flatten()
	_test_stream_reassembly()
	_test_stream_stops()
	_test_stream_failures()
	_test_untyped_error_frame()
	_test_summary_part_separator()
	_test_refusal()
	_test_lifecycle_progress()
	_test_terminal_frames_emit_once()
	_test_completion()
	_test_normalize_base()
	_test_inherited_surface()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Feed each line to a fresh parse pass and collect every canonical event, the way LLMClient's stream loop does.
func _events(adapter: LLMAdapters, lines: Array) -> Array:
	var events: Array = []
	for line in lines:
		events.append_array(adapter.parse_line(String(line)))
	return events


## One SSE data line for `payload`, encoded the way the endpoint frames it.
func _sse(payload: Dictionary) -> String:
	return "data: " + JSON.stringify(payload)


## The first event of `type` among `events`, or {} when none arrived.
func _event_of(events: Array, type: String) -> Dictionary:
	for event in events:
		if event is Dictionary and String(event.get("type", "")) == type:
			return event
	return {}


func _test_chat_body_basics() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var messages: Array = [
		{"role": "system", "content": "You are helpful."},
		{"role": "user", "content": "Hi"},
	]
	var body: Dictionary = adapter.build_chat_body("gpt-5.6-terra", messages, [])
	_check(String(body.get("instructions", "")) == "You are helpful.", "the leading system message lifts to the top-level instructions field")
	_check(bool(body.get("stream", false)), "chat requests stream")
	_check(body.get("store") == false, "requests are stateless (store:false), so the plugin's history stays the only record")
	_check(body.get("include") == ["reasoning.encrypted_content"], "encrypted reasoning is asked for, so a stateless tool loop can echo it")
	_check(not body.has("reasoning"), "no reasoning field when no effort level is selected — the model's defaults prevail")
	_check(not body.has("tools"), "no tools field when none are attached")
	var input: Array = body.get("input", [])
	_check(input.size() == 1 and String(input[0].get("role", "")) == "user" and String(input[0].get("content", "")) == "Hi", "the system message never appears among the input items; the user turn rides as plain string content")


func _test_effort_and_summary() -> void:
	var user_turn: Array = [{"role": "user", "content": "Hi"}]
	var high: Dictionary = LLMAdapters.OpenAIResponsesAdapter.new().build_chat_body("gpt-5.6-terra", user_turn, [], "high")
	_check(high.get("reasoning") is Dictionary and String(high["reasoning"].get("effort", "")) == "high", "a selected level rides reasoning.effort")
	_check(high.get("reasoning") is Dictionary and String(high["reasoning"].get("summary", "")) == "auto", "a reasoning level also asks for the summary trace (the shipped default; see GDLLMSettings.OPENAI_REASONING_SUMMARIES)")
	var none: Dictionary = LLMAdapters.OpenAIResponsesAdapter.new().build_chat_body("gpt-5.6-terra", user_turn, [], "none")
	_check(none.get("reasoning") == {"effort": "none"}, "effort none sends the knob without a summary ask — no reasoning exists to summarize")
	var minimal: Dictionary = LLMAdapters.OpenAIResponsesAdapter.new().build_chat_body("gpt-5", user_turn, [], "minimal")
	_check(minimal.get("reasoning") == {"effort": "minimal"}, "minimal (a GPT-5.0-era level the user config may still offer) passes through, also without a summary ask")


func _test_tool_translation() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var body: Dictionary = adapter.build_chat_body("gpt-5.6-terra", [{"role": "user", "content": "Hi"}], SOME_TOOLS)
	var wire_tools: Array = body.get("tools", [])
	_check(wire_tools.size() == 1, "one tool translated")
	var entry: Dictionary = wire_tools[0] if wire_tools.size() == 1 else {}
	_check(String(entry.get("type", "")) == "function" and String(entry.get("name", "")) == "read_file", "the function envelope flattens — name beside type, no nesting")
	_check(entry.get("parameters") is Dictionary and entry["parameters"].get("required") == ["path"], "the parameters schema rides flat too")
	_check(not entry.has("function"), "no chat-completions envelope leaks through")


func _test_input_translation() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	# A finished tool turn earlier in history, then a fresh user question: the old turn rebuilds from text + synthesized ids, no reasoning items.
	var messages: Array = [
		{"role": "user", "content": "What is in a.gd?"},
		{"role": "assistant", "content": "Checking.", "tool_calls": [
			{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}},
			{"function": {"name": "read_file", "arguments": {"path": "b.gd"}}},
		]},
		{"role": "tool", "content": "contents of a", "tool_name": "read_file"},
		{"role": "tool", "content": "contents of b", "tool_name": "read_file"},
		{"role": "assistant", "content": "Both read."},
		{"role": "user", "content": "Thanks — and c.gd?"},
	]
	var input: Array = adapter.build_chat_body("gpt-5.6-terra", messages, SOME_TOOLS).get("input", [])
	# user, assistant preamble, two function_calls, two outputs, assistant text, user
	_check(input.size() == 8, "the history translates item for item (preamble + 2 calls + 2 outputs between the user turns)")
	var preamble: Dictionary = input[1] if input.size() > 1 else {}
	var preamble_parts: Array = preamble.get("content", []) if preamble.get("content") is Array else []
	_check(preamble_parts.size() == 1 and String(preamble_parts[0].get("type", "")) == "output_text" and String(preamble_parts[0].get("text", "")) == "Checking.", "replayed assistant text is an output_text part — the input_text spelling is rejected on that role")
	var call_a: Dictionary = input[2] if input.size() > 2 else {}
	var call_b: Dictionary = input[3] if input.size() > 3 else {}
	_check(String(call_a.get("type", "")) == "function_call" and String(call_a.get("name", "")) == "read_file", "a stored call rebuilds as a function_call item")
	_check(call_a.get("arguments") is String and String(call_a["arguments"]).contains("a.gd"), "rebuilt call arguments are a JSON string, as the wire wants")
	_check(String(call_a.get("call_id", "")) != "" and call_a.get("call_id") != call_b.get("call_id"), "synthesized call ids are present and distinct")
	var out_a: Dictionary = input[4] if input.size() > 4 else {}
	var out_b: Dictionary = input[5] if input.size() > 5 else {}
	_check(String(out_a.get("type", "")) == "function_call_output" and String(out_a.get("output", "")) == "contents of a", "a tool result becomes a function_call_output item")
	_check(String(out_a.get("call_id", "")) == String(call_a.get("call_id", "")) and String(out_b.get("call_id", "")) == String(call_b.get("call_id", "")), "each output binds to its call's id by order")


func _test_trailing_loop_echo() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var raw_items: Array = [
		{"type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "gAAAA-opaque"},
		{"type": "function_call", "id": "fc_1", "call_id": "call_real_1", "name": "read_file", "arguments": "{\"path\": \"a.gd\"}"},
	]
	var messages: Array = [
		{"role": "user", "content": "What is in a.gd?"},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}}], "assistant_blocks": raw_items},
		{"role": "tool", "content": "contents of a", "tool_name": "read_file"},
	]
	var input: Array = adapter.build_chat_body("gpt-5.6-terra", messages, SOME_TOOLS).get("input", [])
	_check(input.size() == 4 and input[1] == raw_items[0] and input[2] == raw_items[1], "a call turn inside the active tool loop echoes its raw output items verbatim, encrypted reasoning intact — the API 400s on a dropped item")
	var result: Dictionary = input[3] if input.size() > 3 else {}
	_check(String(result.get("call_id", "")) == "call_real_1", "the result binds to the real call_id from the raw items")
	# The same turn behind a later user message is out of the loop: past reasoning must not be re-sent.
	messages.append({"role": "user", "content": "Now explain it."})
	input = LLMAdapters.OpenAIResponsesAdapter.new().build_chat_body("gpt-5.6-terra", messages, SOME_TOOLS).get("input", [])
	var has_reasoning := false
	for item in input:
		if item is Dictionary and String(item.get("type", "")) == "reasoning":
			has_reasoning = true
	_check(not has_reasoning, "a call turn behind a newer user message rebuilds without its reasoning items")


func _test_kind_switch_fallback() -> void:
	# A trailing loop recorded under the other kind must not replay alien items: the source's Kind can switch mid-loop (a Connections save reconfigures open sessions immediately), and each API 400s on the other's block types.
	var anthropic_recorded: Array = [
		{"role": "user", "content": "What is in a.gd?"},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}}], "assistant_blocks": [
			{"type": "thinking", "thinking": "Anthropic trace", "signature": "sig"},
			{"type": "tool_use", "id": "toolu_1", "name": "read_file", "input": {"path": "a.gd"}},
		]},
		{"role": "tool", "content": "contents of a", "tool_name": "read_file"},
	]
	var input: Array = LLMAdapters.OpenAIResponsesAdapter.new().build_chat_body("gpt-5.6-terra", anthropic_recorded, SOME_TOOLS).get("input", [])
	var alien := false
	var call_id := ""
	for item in input:
		if item is Dictionary:
			if ["thinking", "tool_use"].has(String(item.get("type", ""))):
				alien = true
			if String(item.get("type", "")) == "function_call":
				call_id = String(item.get("call_id", ""))
	_check(not alien, "anthropic-recorded blocks never replay to the Responses API; the turn rebuilds")
	_check(call_id.begins_with("call_gdllm"), "the rebuilt turn synthesizes its own call ids")
	var output_item := {}
	for item in input:
		if item is Dictionary and String(item.get("type", "")) == "function_call_output":
			output_item = item
	_check(String(output_item.get("call_id", "")) == call_id, "the tool result binds to the synthesized id, not an alien one")
	# The mirror direction: Responses-recorded items must not replay to Anthropic.
	var responses_recorded: Array = [
		{"role": "user", "content": "What is in a.gd?"},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}}], "assistant_blocks": [
			{"type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "gAAAA-opaque"},
			{"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "read_file", "arguments": "{\"path\": \"a.gd\"}"},
		]},
		{"role": "tool", "content": "contents of a", "tool_name": "read_file"},
	]
	var wire: Array = LLMAdapters.AnthropicAdapter.new().build_chat_body("claude-opus-4-8", responses_recorded, SOME_TOOLS).get("messages", [])
	var blocks: Array = wire[1].get("content", []) if wire.size() > 1 and wire[1].get("content") is Array else []
	var anthropic_alien := false
	var tool_use_id := ""
	for block in blocks:
		if block is Dictionary:
			if ["reasoning", "function_call"].has(String(block.get("type", ""))):
				anthropic_alien = true
			if String(block.get("type", "")) == "tool_use":
				tool_use_id = String(block.get("id", ""))
	_check(not anthropic_alien, "responses-recorded items never replay to Anthropic; the turn rebuilds")
	var results: Array = wire[2].get("content", []) if wire.size() > 2 and wire[2].get("content") is Array else []
	_check(results.size() == 1 and String(results[0].get("tool_use_id", "")) == tool_use_id and tool_use_id.begins_with("toolu_gdllm"), "the anthropic rebuild binds its result to the synthesized tool_use id")


func _test_toolless_flatten() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	# The loop-brake reflection and a subagent's forced answer send tool-bearing history with NO tools param; flattening keeps such a request from carrying tool items it never declared.
	var messages: Array = [
		{"role": "user", "content": "What is in a.gd?"},
		{"role": "assistant", "content": "Checking.", "tool_calls": [{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}}]},
		{"role": "tool", "content": "contents of a", "tool_name": "read_file"},
		{"role": "user", "content": "Stop searching and answer."},
	]
	var input: Array = adapter.build_chat_body("gpt-5.6-terra", messages, []).get("input", [])
	var has_tool_items := false
	for item in input:
		if item is Dictionary and (String(item.get("type", "")) == "function_call" or String(item.get("type", "")) == "function_call_output"):
			has_tool_items = true
	_check(not has_tool_items, "a tool-less request carries no function_call/function_call_output items at all")
	var call_parts: Array = input[1].get("content", []) if input.size() > 1 and input[1].get("content") is Array else []
	var call_text := String(call_parts[0].get("text", "")) if call_parts.size() == 1 else ""
	_check(call_text.contains("Checking.") and call_text.contains("[called read_file("), "the call turn flattens to its preamble plus a readable call line")
	var result_text := String(input[2].get("content", "")) if input.size() > 2 else ""
	_check(result_text.begins_with("[read_file result]"), "the tool result flattens to a labeled user message")


func _test_stream_reassembly() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var reasoning_item := {"type": "reasoning", "id": "rs_9", "summary": [{"type": "summary_text", "text": "Reading it."}], "encrypted_content": "gAAAA-opaque"}
	var call_item := {"type": "function_call", "id": "fc_9", "call_id": "call_9", "name": "read_file", "arguments": "{\"path\": \"a.gd\"}", "status": "completed"}
	var events := _events(adapter, [
		"event: response.created",
		_sse({"type": "response.created", "response": {"id": "resp_1", "status": "in_progress"}, "sequence_number": 0}),
		"",
		_sse({"type": "response.in_progress", "response": {"id": "resp_1"}, "sequence_number": 1}),
		_sse({"type": "response.output_item.added", "output_index": 0, "item": {"type": "reasoning", "id": "rs_9"}}),
		_sse({"type": "response.reasoning_summary_text.delta", "item_id": "rs_9", "summary_index": 0, "delta": "Reading "}),
		_sse({"type": "response.reasoning_summary_text.delta", "item_id": "rs_9", "summary_index": 0, "delta": "it."}),
		_sse({"type": "response.output_item.done", "output_index": 0, "item": reasoning_item}),
		_sse({"type": "response.output_item.added", "output_index": 1, "item": {"type": "message", "id": "msg_9"}}),
		_sse({"type": "response.output_text.delta", "item_id": "msg_9", "content_index": 0, "delta": "Reading "}),
		_sse({"type": "response.output_text.delta", "item_id": "msg_9", "content_index": 0, "delta": "now."}),
		_sse({"type": "response.output_item.done", "output_index": 1, "item": {"type": "message", "id": "msg_9", "content": [{"type": "output_text", "text": "Reading now."}]}}),
		_sse({"type": "response.function_call_arguments.delta", "item_id": "fc_9", "delta": "{\"path\""}),
		_sse({"type": "response.output_item.done", "output_index": 2, "item": call_item}),
		_sse({"type": "response.completed", "response": {"id": "resp_1", "status": "completed", "output": [reasoning_item, {"type": "message", "id": "msg_9", "content": [{"type": "output_text", "text": "Reading now."}]}, call_item], "usage": {"input_tokens": 100, "output_tokens": 42, "total_tokens": 142}}}),
	])
	_check(not _event_of(events, "progress").is_empty(), "the lifecycle frames yield a progress event, so the wire-format guard sees the reply parse before any visible delta")
	var thinking_text := ""
	var content_text := ""
	for event in events:
		if String(event.get("type", "")) == "thinking":
			thinking_text += String(event.get("text", ""))
		elif String(event.get("type", "")) == "content":
			content_text += String(event.get("text", ""))
	_check(thinking_text == "Reading it.", "reasoning summary deltas stream as canonical thinking events")
	_check(content_text == "Reading now.", "output text deltas stream as canonical content events")
	var calls: Array = _event_of(events, "tool_calls").get("calls", [])
	_check(calls == [{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}}], "the finalized function_call item's argument string parses into one canonical call")
	var blocks: Array = _event_of(events, "assistant_blocks").get("blocks", [])
	_check(blocks.size() == 3 and blocks[0] == reasoning_item, "the terminal frame's authoritative output items are handed back for the echo, encrypted reasoning first")
	var stats: Dictionary = _event_of(events, "done").get("stats", {})
	_check(int(stats.get("tokens_in", 0)) == 100 and int(stats.get("tokens_out", 0)) == 42, "usage comes from the terminal frame under this API's input_tokens/output_tokens names")
	_check(String(_event_of(events, "done").get("stop", "?")) == "", "a completed response is a normal finish")


func _test_stream_stops() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var events := _events(adapter, [
		_sse({"type": "response.output_text.delta", "delta": "Half an ans"}),
		_sse({"type": "response.incomplete", "response": {"status": "incomplete", "incomplete_details": {"reason": "max_output_tokens"}, "output": [], "usage": {"input_tokens": 10, "output_tokens": 7}}}),
	])
	_check(String(_event_of(events, "done").get("stop", "?")) == "length", "max_output_tokens canonicalizes to the length stop, so a capped reply is disclosed")
	_check(int(_event_of(events, "done").get("stats", {}).get("tokens_out", 0)) == 7, "an incomplete response still reports its usage")
	adapter = LLMAdapters.OpenAIResponsesAdapter.new()
	events = _events(adapter, [
		_sse({"type": "response.incomplete", "response": {"status": "incomplete", "incomplete_details": {"reason": "content_filter"}}}),
	])
	_check(String(_event_of(events, "done").get("stop", "?")) == "content_filter", "any other incomplete reason passes through verbatim, still disclosed by name")


func _test_stream_failures() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var events := _events(adapter, [
		_sse({"type": "response.failed", "response": {"status": "failed", "error": {"code": "server_error", "message": "The model backend crashed."}}}),
	])
	var failed: Dictionary = _event_of(events, "error")
	_check(String(failed.get("message", "")) == "server_error: The model backend crashed.", "a failed response reports its code and message")
	adapter = LLMAdapters.OpenAIResponsesAdapter.new()
	events = _events(adapter, [
		_sse({"type": "error", "code": "rate_limit_exceeded", "message": "Slow down.", "param": null, "sequence_number": 3}),
	])
	_check(String(_event_of(events, "error").get("message", "")) == "rate_limit_exceeded: Slow down.", "a stream-level error frame reports its code and message too")


func _test_untyped_error_frame() -> void:
	# LiteLLM-style proxies report mid-stream failures as typeless {"error": {...}} frames; dropping one would hide the provider's real complaint behind a wire-format attribution.
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var events := _events(adapter, [_sse({"error": {"message": "context length exceeded", "code": "context_overflow"}})])
	_check(String(_event_of(events, "error").get("message", "")) == "context length exceeded", "a typeless proxy error frame surfaces its message instead of being dropped")


func _test_summary_part_separator() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var events := _events(adapter, [
		_sse({"type": "response.reasoning_summary_part.added", "item_id": "rs_1", "summary_index": 0, "part": {"type": "summary_text", "text": ""}}),
		_sse({"type": "response.reasoning_summary_text.delta", "item_id": "rs_1", "summary_index": 0, "delta": "First part."}),
		_sse({"type": "response.reasoning_summary_part.added", "item_id": "rs_1", "summary_index": 1, "part": {"type": "summary_text", "text": ""}}),
		_sse({"type": "response.reasoning_summary_text.delta", "item_id": "rs_1", "summary_index": 1, "delta": "Second part."}),
		# A multi-tool turn carries a second reasoning item, whose summary_index restarts at 0 — the item boundary itself must break.
		_sse({"type": "response.reasoning_summary_part.added", "item_id": "rs_2", "summary_index": 0, "part": {"type": "summary_text", "text": ""}}),
		_sse({"type": "response.reasoning_summary_text.delta", "item_id": "rs_2", "summary_index": 0, "delta": "Next item."}),
	])
	var thinking := ""
	for event in events:
		if String(event.get("type", "")) == "thinking":
			thinking += String(event.get("text", ""))
	_check(thinking == "First part.\n\nSecond part.\n\nNext item.", "summary parts and a following reasoning item each open their own paragraph instead of gluing on")


func _test_refusal() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var events := _events(adapter, [
		_sse({"type": "response.refusal.delta", "delta": "I can't"}),
		_sse({"type": "response.refusal.done", "refusal": "I can't help with that."}),
		_sse({"type": "response.completed", "response": {"status": "completed", "output": [], "usage": {"input_tokens": 5, "output_tokens": 1}}}),
	])
	var error := _event_of(events, "error")
	_check(String(error.get("message", "")).contains("refusal") and String(error.get("message", "")).contains("I can't help with that."), "a refusal surfaces as a clear error carrying the model's explanation")
	_check(_event_of(events, "done").is_empty(), "the trailing completed frame cannot dress the refusal up as a finished turn")


func _test_lifecycle_progress() -> void:
	# A proxy may drop response.created/in_progress; any recognized lifecycle frame must still prove the wire format before the first visible delta, or a silent-reasoning stream dies at the idle timeout.
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var events := _events(adapter, [_sse({"type": "response.output_item.added", "output_index": 0, "item": {"type": "reasoning", "id": "rs_1"}})])
	_check(not _event_of(events, "progress").is_empty(), "output_item.added alone feeds the wire-format guard")
	_check(LLMAdapters.OpenAIResponsesAdapter.new().parse_line("data: {\"type\": \"pong\"}").is_empty(), "an unrecognized frame type still yields nothing")


func _test_terminal_frames_emit_once() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var events := _events(adapter, [
		_sse({"type": "response.output_text.delta", "delta": "All done."}),
		_sse({"type": "response.completed", "response": {"status": "completed", "output": [], "usage": {"input_tokens": 5, "output_tokens": 3}}}),
		_sse({"type": "response.completed", "response": {"status": "completed", "output": [], "usage": {"input_tokens": 5, "output_tokens": 3}}}),
	])
	var done_count := 0
	for event in events:
		if String(event.get("type", "")) == "done":
			done_count += 1
	_check(done_count == 1, "a repeated terminal frame (a gateway quirk) cannot double-emit the finish")


func _test_completion() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	var req: Dictionary = adapter.completion_request("gpt-5.6-luna", "Be brief.", "Title this chat")
	_check(String(req.get("path", "")) == "/responses", "completions post to the responses endpoint")
	var body: Dictionary = req.get("body", {})
	_check(body.get("input") == [{"role": "user", "content": "Title this chat"}], "the completion input is an explicit one-item list — the subscription backend rejects the string shorthand")
	_check(String(body.get("instructions", "")) == "Be brief." and body.get("store") == false and not body.has("stream"), "the completion body is a one-shot stateless request with instructions")
	var reply := adapter.parse_completion({"output": [
		{"type": "reasoning", "id": "rs_1", "summary": []},
		{"type": "message", "id": "msg_1", "content": [{"type": "output_text", "text": "A Good Title"}]},
	]})
	_check(reply == "A Good Title", "parse_completion skips reasoning items to the first message's output_text")
	var stats: Dictionary = adapter.parse_completion_stats({"usage": {"input_tokens": 12, "output_tokens": 4}})
	_check(int(stats.get("tokens_in", 0)) == 12 and int(stats.get("tokens_out", 0)) == 4, "completion usage maps through the same input_tokens/output_tokens rule")


func _test_normalize_base() -> void:
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	_check(adapter.normalize_base("https://api.openai.com/v1") == "https://api.openai.com/v1", "the /v1 base is respected as-is")
	_check(adapter.normalize_base("https://api.openai.com/v1/responses") == "https://api.openai.com/v1", "a pasted responses endpoint reduces to its /v1 base")
	_check(adapter.normalize_base("https://api.openai.com") == "https://api.openai.com/v1", "a pathless base gets /v1 appended")
	_check(adapter.normalize_base("https://api.openai.com/v1/chat/completions") == "https://api.openai.com/v1", "the parent's suffixes still strip — a chat-completions URL pasted onto this kind reduces the same way")
	_check(adapter.normalize_base("https://gw.example/llm/v1") == "https://gw.example/llm/v1", "a gateway prefix is respected as-is")


func _test_inherited_surface() -> void:
	# The model list, window probe, and auth ride the OpenAIAdapter surface unchanged; pin that the inheritance holds.
	var adapter := LLMAdapters.OpenAIResponsesAdapter.new()
	_check(adapter.models_path() == "/models", "the model list uses the shared /v1/models path")
	var names := adapter.parse_models({"data": [{"id": "gpt-5.6-terra"}, {"id": "gpt-4o"}]})
	_check(names.size() == 2 and names.has("gpt-5.6-terra"), "the model list parses out of the data array")
	var probe: Dictionary = adapter.context_probe("gpt-5.6-terra")
	_check(String(probe.get("path", "")) == "/models", "the window probe reads the shared models list")
	_check(adapter.auth_headers("sk-test").has("Authorization: Bearer sk-test"), "auth is the shared Bearer token")
	_check(adapter.chat_path() == "/responses", "while the chat path is this API's own")
