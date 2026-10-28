import Foundation
import Testing
@testable import PiAI

// Replays /tmp/pi-live/fixtures/anthropic-* (recorded from upstream TS `streamSimple` against a local GLM endpoint).
// Expected events, final messages, truncation and abort outcomes were produced by running upstream
// packages/ai/dist/api/anthropic-messages.js over the same bytes with a fake fetch.

// MARK: - Fixtures (verbatim bytes)

private let thinkRequestHead = #"""
{"path": "/v1/messages?beta=true", "headers": {"host": "127.0.0.1:3426", "connection": "keep-alive", "X-Stainless-Retry-Count": "0", "X-Stainless-Timeout": "600", "X-Stainless-Lang": "js", "X-Stainless-Package-Version": "0.129.0", "X-Stainless-OS": "MacOS", "X-Stainless-Arch": "arm64", "X-Stainless-Runtime": "node", "X-Stainless-Runtime-Version": "v25.9.0", "anthropic-version": "2023-06-01", "x-api-key": "magpie", "User-Agent": "pi (darwin 27.2.0; arm64)", "accept": "application/json", "anthropic-dangerous-direct-browser-access": "true", "content-type": "application/json", "anthropic-beta": "interleaved-thinking-2025-05-14", "accept-language": "*", "sec-fetch-mode": "cors", "accept-encoding": "gzip, deflate", "content-length": "852"}}
"""#
private let thinkRequestBody = #"""
{"model":"zcode/GLM-5.3-Flash","messages":[{"role":"user","content":[{"type":"text","text":"What is 17*23? Answer with only the number.","cache_control":{"type":"ephemeral"}}]}],"max_tokens":32000,"stream":true,"system":[{"type":"text","text":"You are a helpful assistant with access to workspace tools.","cache_control":{"type":"ephemeral"}}],"tools":[{"name":"ls","description":"List files in the workspace directory.","eager_input_streaming":true,"input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":[]}},{"name":"read","description":"Read a file in the workspace by relative path.","eager_input_streaming":true,"input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},"cache_control":{"type":"ephemeral"}}],"thinking":{"type":"enabled","budget_tokens":16384,"display":"summarized"}}
"""#
private let thinkSse = #"""
event: message_start
data: {"type": "message_start", "message": {"id": "msg_20261021140138e967e7b9c47b4e72", "type": "message", "role": "assistant", "model": "GLM-5.3-Flash", "content": [], "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 0, "output_tokens": 0}}}

event: ping
data: {"type": "ping"}

event: content_block_start
data: {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "The"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " user"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " wants"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " me"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " to"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " compute"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " "}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "17"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "*"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "23"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " and"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " answer"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " with"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " only"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " the"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " number"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "."}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " This"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " is"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " simple"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " math"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": ":"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " "}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "17"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "*"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "23"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " ="}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": " "}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "39"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "1"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "."}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "58e27a39fc5a4675af884b53"}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 0}

event: content_block_start
data: {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "39"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "1"}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 1}

event: message_delta
data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}, "usage": {"input_tokens": 224, "output_tokens": 35, "cache_read_input_tokens": 0, "server_tool_use": {"web_search_requests": 0}, "service_tier": "standard"}}

event: message_stop
data: {"type": "message_stop"}


"""#
private let thinkSseByteCount = 5642

private let t1RequestHead = #"""
{"path": "/v1/messages?beta=true", "headers": {"host": "127.0.0.1:3426", "connection": "keep-alive", "X-Stainless-Retry-Count": "0", "X-Stainless-Timeout": "600", "X-Stainless-Lang": "js", "X-Stainless-Package-Version": "0.129.0", "X-Stainless-OS": "MacOS", "X-Stainless-Arch": "arm64", "X-Stainless-Runtime": "node", "X-Stainless-Runtime-Version": "v25.9.0", "anthropic-version": "2023-06-01", "x-api-key": "magpie", "User-Agent": "pi (darwin 27.2.0; arm64)", "accept": "application/json", "anthropic-dangerous-direct-browser-access": "true", "content-type": "application/json", "anthropic-beta": "interleaved-thinking-2025-05-14", "accept-language": "*", "sec-fetch-mode": "cors", "accept-encoding": "gzip, deflate", "content-length": "913"}}
"""#
private let t1RequestBody = #"""
{"model":"zcode/GLM-5.3-Flash","messages":[{"role":"user","content":[{"type":"text","text":"Use the tools to list the files in the workspace, then read every file, and tell me their exact contents.","cache_control":{"type":"ephemeral"}}]}],"max_tokens":32000,"stream":true,"system":[{"type":"text","text":"You are a helpful assistant with access to workspace tools.","cache_control":{"type":"ephemeral"}}],"tools":[{"name":"ls","description":"List files in the workspace directory.","eager_input_streaming":true,"input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":[]}},{"name":"read","description":"Read a file in the workspace by relative path.","eager_input_streaming":true,"input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},"cache_control":{"type":"ephemeral"}}],"thinking":{"type":"enabled","budget_tokens":2048,"display":"summarized"}}
"""#
private let t1Sse = #"""
event: message_start
data: {"type": "message_start", "message": {"id": "msg_202610211401445230170091034799", "type": "message", "role": "assistant", "model": "GLM-5.3-Flash", "content": [], "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 0, "output_tokens": 0}}}

event: ping
data: {"type": "ping"}

event: content_block_start
data: {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "call_da17dd082873488da5dd67f2", "name": "ls", "input": {}}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "{}"}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 0}

event: message_delta
data: {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": null}, "usage": {"input_tokens": 234, "output_tokens": 5, "cache_read_input_tokens": 0, "server_tool_use": {"web_search_requests": 0}, "service_tier": "standard"}}

event: message_stop
data: {"type": "message_stop"}


"""#
private let t1SseByteCount = 1044

private let t2RequestHead = #"""
{"path": "/v1/messages?beta=true", "headers": {"host": "127.0.0.1:3426", "connection": "keep-alive", "X-Stainless-Retry-Count": "0", "X-Stainless-Timeout": "600", "X-Stainless-Lang": "js", "X-Stainless-Package-Version": "0.129.0", "X-Stainless-OS": "MacOS", "X-Stainless-Arch": "arm64", "X-Stainless-Runtime": "node", "X-Stainless-Runtime-Version": "v25.9.0", "anthropic-version": "2023-06-01", "x-api-key": "magpie", "User-Agent": "pi (darwin 27.2.0; arm64)", "accept": "application/json", "anthropic-dangerous-direct-browser-access": "true", "content-type": "application/json", "anthropic-beta": "interleaved-thinking-2025-05-14", "accept-language": "*", "sec-fetch-mode": "cors", "accept-encoding": "gzip, deflate", "content-length": "1165"}}
"""#
private let t2RequestBody = #"""
{"model":"zcode/GLM-5.3-Flash","messages":[{"role":"user","content":[{"type":"text","text":"Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."}]},{"role":"assistant","content":[{"type":"tool_use","id":"call_da17dd082873488da5dd67f2","name":"ls","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_da17dd082873488da5dd67f2","content":"a.txt\nb.txt","is_error":false,"cache_control":{"type":"ephemeral"}}]}],"max_tokens":32000,"stream":true,"system":[{"type":"text","text":"You are a helpful assistant with access to workspace tools.","cache_control":{"type":"ephemeral"}}],"tools":[{"name":"ls","description":"List files in the workspace directory.","eager_input_streaming":true,"input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":[]}},{"name":"read","description":"Read a file in the workspace by relative path.","eager_input_streaming":true,"input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},"cache_control":{"type":"ephemeral"}}],"thinking":{"type":"enabled","budget_tokens":2048,"display":"summarized"}}
"""#
private let t2Sse = #"""
event: message_start
data: {"type": "message_start", "message": {"id": "msg_202610211401507f6a2223244e48f5", "type": "message", "role": "assistant", "model": "GLM-5.3-Flash", "content": [], "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 0, "output_tokens": 0}}}

event: ping
data: {"type": "ping"}

event: content_block_start
data: {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "call_f764f355ab3e444d8f6cd4fa", "name": "read", "input": {}}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "{\""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "path"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "\":\""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "a"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": ".txt"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "\""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "}"}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 0}

event: content_block_start
data: {"type": "content_block_start", "index": 1, "content_block": {"type": "tool_use", "id": "call_c54d69088d9f405d987bda85", "name": "read", "input": {}}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": "{\""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": "path"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": "\":\""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": "b"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": ".txt"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": "\""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": "}"}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 1}

event: message_delta
data: {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": null}, "usage": {"input_tokens": 248, "output_tokens": 22, "cache_read_input_tokens": 0, "server_tool_use": {"web_search_requests": 0}, "service_tier": "standard"}}

event: message_stop
data: {"type": "message_stop"}


"""#
private let t2SseByteCount = 3127

private let t3RequestHead = #"""
{"path": "/v1/messages?beta=true", "headers": {"host": "127.0.0.1:3426", "connection": "keep-alive", "X-Stainless-Retry-Count": "0", "X-Stainless-Timeout": "600", "X-Stainless-Lang": "js", "X-Stainless-Package-Version": "0.129.0", "X-Stainless-OS": "MacOS", "X-Stainless-Arch": "arm64", "X-Stainless-Runtime": "node", "X-Stainless-Runtime-Version": "v25.9.0", "anthropic-version": "2023-06-01", "x-api-key": "magpie", "User-Agent": "pi (darwin 27.2.0; arm64)", "accept": "application/json", "anthropic-dangerous-direct-browser-access": "true", "content-type": "application/json", "anthropic-beta": "interleaved-thinking-2025-05-14", "accept-language": "*", "sec-fetch-mode": "cors", "accept-encoding": "gzip, deflate", "content-length": "1629"}}
"""#
private let t3RequestBody = #"""
{"model":"zcode/GLM-5.3-Flash","messages":[{"role":"user","content":[{"type":"text","text":"Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."}]},{"role":"assistant","content":[{"type":"tool_use","id":"call_da17dd082873488da5dd67f2","name":"ls","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_da17dd082873488da5dd67f2","content":"a.txt\nb.txt","is_error":false}]},{"role":"assistant","content":[{"type":"tool_use","id":"call_f764f355ab3e444d8f6cd4fa","name":"read","input":{"path":"a.txt"}},{"type":"tool_use","id":"call_c54d69088d9f405d987bda85","name":"read","input":{"path":"b.txt"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_f764f355ab3e444d8f6cd4fa","content":"alpha\n","is_error":false},{"type":"tool_result","tool_use_id":"call_c54d69088d9f405d987bda85","content":"beta\n","is_error":false,"cache_control":{"type":"ephemeral"}}]}],"max_tokens":32000,"stream":true,"system":[{"type":"text","text":"You are a helpful assistant with access to workspace tools.","cache_control":{"type":"ephemeral"}}],"tools":[{"name":"ls","description":"List files in the workspace directory.","eager_input_streaming":true,"input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":[]}},{"name":"read","description":"Read a file in the workspace by relative path.","eager_input_streaming":true,"input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},"cache_control":{"type":"ephemeral"}}],"thinking":{"type":"enabled","budget_tokens":2048,"display":"summarized"}}
"""#
private let t3Sse = #"""
event: message_start
data: {"type": "message_start", "message": {"id": "msg_20261021140155bfc96c24a3294248", "type": "message", "role": "assistant", "model": "GLM-5.3-Flash", "content": [], "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 0, "output_tokens": 0}}}

event: ping
data: {"type": "ping"}

event: content_block_start
data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "The"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": " workspace"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": " has"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": " two"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": " files"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": ":\n\n"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "**"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "a"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": ".txt"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "**\n"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "``"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "`\n"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "alpha"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "\n"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "``"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "`\n\n"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "**"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "b"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": ".txt"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "**\n"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "``"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "`\n"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "beta"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "\n"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "```"}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 0}

event: message_delta
data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}, "usage": {"input_tokens": 280, "output_tokens": 27, "cache_read_input_tokens": 0, "server_tool_use": {"web_search_requests": 0}, "service_tier": "standard"}}

event: message_stop
data: {"type": "message_stop"}


"""#
private let t3SseByteCount = 4010

// MARK: - Upstream expectations

private struct ExpectedEvent { var type: String; var index: Int?; var delta: String?; var args: String? }

private let thinkEvents: [ExpectedEvent] = [
    ExpectedEvent(type: "start", index: nil, delta: nil, args: nil),
    ExpectedEvent(type: "thinking_start", index: 0, delta: nil, args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: "The", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " user", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " wants", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " me", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " to", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " compute", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " ", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: "17", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: "*", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: "23", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " and", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " answer", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " with", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " only", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " the", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " number", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: ".", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " This", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " is", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " simple", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " math", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: ":", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " ", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: "17", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: "*", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: "23", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " =", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: " ", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: "39", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: "1", args: nil),
    ExpectedEvent(type: "thinking_delta", index: 0, delta: ".", args: nil),
    ExpectedEvent(type: "thinking_end", index: 0, delta: nil, args: nil),
    ExpectedEvent(type: "text_start", index: 1, delta: nil, args: nil),
    ExpectedEvent(type: "text_delta", index: 1, delta: "39", args: nil),
    ExpectedEvent(type: "text_delta", index: 1, delta: "1", args: nil),
    ExpectedEvent(type: "text_end", index: 1, delta: nil, args: nil),
    ExpectedEvent(type: "done", index: nil, delta: nil, args: nil),
]
private let thinkResult = #"""
{"role":"assistant","content":[{"type":"thinking","thinking":"The user wants me to compute 17*23 and answer with only the number. This is simple math: 17*23 = 391.","thinkingSignature":"58e27a39fc5a4675af884b53"},{"type":"text","text":"391"}],"api":"anthropic-messages","provider":"anthropic","model":"zcode/GLM-5.3-Flash","usage":{"input":224,"output":35,"cacheRead":0,"cacheWrite":0,"totalTokens":259,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cacheWrite1h":0},"stopReason":"stop","responseId":"msg_20261021140138e967e7b9c47b4e72","responseModel":"GLM-5.3-Flash","rawStopReason":"end_turn","durationMs":30}
"""#

private let t1Events: [ExpectedEvent] = [
    ExpectedEvent(type: "start", index: nil, delta: nil, args: nil),
    ExpectedEvent(type: "toolcall_start", index: 0, delta: nil, args: "{}"),
    ExpectedEvent(type: "toolcall_delta", index: 0, delta: "{}", args: "{}"),
    ExpectedEvent(type: "toolcall_end", index: 0, delta: nil, args: "{}"),
    ExpectedEvent(type: "done", index: nil, delta: nil, args: nil),
]
private let t1Result = #"""
{"role":"assistant","content":[{"type":"toolCall","id":"call_da17dd082873488da5dd67f2","name":"ls","arguments":{}}],"api":"anthropic-messages","provider":"anthropic","model":"zcode/GLM-5.3-Flash","usage":{"input":234,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":239,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cacheWrite1h":0},"stopReason":"toolUse","responseId":"msg_202610211401445230170091034799","responseModel":"GLM-5.3-Flash","rawStopReason":"tool_use","durationMs":1}
"""#

private let t2Events: [ExpectedEvent] = [
    ExpectedEvent(type: "start", index: nil, delta: nil, args: nil),
    ExpectedEvent(type: "toolcall_start", index: 0, delta: nil, args: "{}"),
    ExpectedEvent(type: "toolcall_delta", index: 0, delta: "{\"", args: "{}"),
    ExpectedEvent(type: "toolcall_delta", index: 0, delta: "path", args: "{}"),
    ExpectedEvent(type: "toolcall_delta", index: 0, delta: "\":\"", args: "{\"path\":\"\"}"),
    ExpectedEvent(type: "toolcall_delta", index: 0, delta: "a", args: "{\"path\":\"a\"}"),
    ExpectedEvent(type: "toolcall_delta", index: 0, delta: ".txt", args: "{\"path\":\"a.txt\"}"),
    ExpectedEvent(type: "toolcall_delta", index: 0, delta: "\"", args: "{\"path\":\"a.txt\"}"),
    ExpectedEvent(type: "toolcall_delta", index: 0, delta: "}", args: "{\"path\":\"a.txt\"}"),
    ExpectedEvent(type: "toolcall_end", index: 0, delta: nil, args: "{\"path\":\"a.txt\"}"),
    ExpectedEvent(type: "toolcall_start", index: 1, delta: nil, args: "{}"),
    ExpectedEvent(type: "toolcall_delta", index: 1, delta: "{\"", args: "{}"),
    ExpectedEvent(type: "toolcall_delta", index: 1, delta: "path", args: "{}"),
    ExpectedEvent(type: "toolcall_delta", index: 1, delta: "\":\"", args: "{\"path\":\"\"}"),
    ExpectedEvent(type: "toolcall_delta", index: 1, delta: "b", args: "{\"path\":\"b\"}"),
    ExpectedEvent(type: "toolcall_delta", index: 1, delta: ".txt", args: "{\"path\":\"b.txt\"}"),
    ExpectedEvent(type: "toolcall_delta", index: 1, delta: "\"", args: "{\"path\":\"b.txt\"}"),
    ExpectedEvent(type: "toolcall_delta", index: 1, delta: "}", args: "{\"path\":\"b.txt\"}"),
    ExpectedEvent(type: "toolcall_end", index: 1, delta: nil, args: "{\"path\":\"b.txt\"}"),
    ExpectedEvent(type: "done", index: nil, delta: nil, args: nil),
]
private let t2Result = #"""
{"role":"assistant","content":[{"type":"toolCall","id":"call_f764f355ab3e444d8f6cd4fa","name":"read","arguments":{"path":"a.txt"}},{"type":"toolCall","id":"call_c54d69088d9f405d987bda85","name":"read","arguments":{"path":"b.txt"}}],"api":"anthropic-messages","provider":"anthropic","model":"zcode/GLM-5.3-Flash","usage":{"input":248,"output":22,"cacheRead":0,"cacheWrite":0,"totalTokens":270,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cacheWrite1h":0},"stopReason":"toolUse","responseId":"msg_202610211401507f6a2223244e48f5","responseModel":"GLM-5.3-Flash","rawStopReason":"tool_use","durationMs":1}
"""#

private let t3Events: [ExpectedEvent] = [
    ExpectedEvent(type: "start", index: nil, delta: nil, args: nil),
    ExpectedEvent(type: "text_start", index: 0, delta: nil, args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "The", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: " workspace", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: " has", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: " two", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: " files", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: ":\n\n", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "**", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "a", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: ".txt", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "**\n", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "``", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "`\n", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "alpha", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "\n", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "``", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "`\n\n", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "**", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "b", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: ".txt", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "**\n", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "``", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "`\n", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "beta", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "\n", args: nil),
    ExpectedEvent(type: "text_delta", index: 0, delta: "```", args: nil),
    ExpectedEvent(type: "text_end", index: 0, delta: nil, args: nil),
    ExpectedEvent(type: "done", index: nil, delta: nil, args: nil),
]
private let t3Result = #"""
{"role":"assistant","content":[{"type":"text","text":"The workspace has two files:\n\n**a.txt**\n```\nalpha\n```\n\n**b.txt**\n```\nbeta\n```"}],"api":"anthropic-messages","provider":"anthropic","model":"zcode/GLM-5.3-Flash","usage":{"input":280,"output":27,"cacheRead":0,"cacheWrite":0,"totalTokens":307,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cacheWrite1h":0},"stopReason":"stop","responseId":"msg_20261021140155bfc96c24a3294248","responseModel":"GLM-5.3-Flash","rawStopReason":"end_turn","durationMs":1}
"""#

private let thinkTruncations: [(cut: Int, events: Int, last: String, stop: String, error: String?)] = [
    (0, 2, "error", "error", "Anthropic stream ended without a stop reason"),
    (1, 2, "error", "error", "Anthropic stream ended without a stop reason"),
    (10, 2, "error", "error", "Anthropic stream ended without a stop reason"),
    (100, 2, "error", "error", "Could not parse Anthropic SSE event message_start: Unterminated string in JSON at position 73 (line 1 column 74); data={\"type\": \"message_start\", \"message\": {\"id\": \"msg_20261021140138e967e7b9c4; raw=event: message_start\\ndata: {\"type\": \"message_start\", \"message\": {\"id\": \"msg_20261021140138e967e7b9c4"),
    (250, 2, "error", "error", "Could not parse Anthropic SSE event message_start: Unterminated string in JSON at position 223 (line 1 column 224); data={\"type\": \"message_start\", \"message\": {\"id\": \"msg_20261021140138e967e7b9c47b4e72\", \"type\": \"message\", \"role\": \"assistant\", \"model\": \"GLM-5.3-Flash\", \"content\": [], \"stop_reason\": null, \"stop_sequence\": null, \"usage\": {\"input; raw=event: message_start\\ndata: {\"type\": \"message_start\", \"message\": {\"id\": \"msg_20261021140138e967e7b9c47b4e72\", \"type\": \"message\", \"role\": \"assistant\", \"model\": \"GLM-5.3-Flash\", \"content\": [], \"stop_reason\": null, \"stop_sequence\": null, \"usage\": {\"input"),
    (400, 2, "error", "error", "Could not parse Anthropic SSE event content_block_start: Unterminated string in JSON at position 45 (line 1 column 46); data={\"type\": \"content_block_start\", \"index\": 0, \"; raw=event: content_block_start\\ndata: {\"type\": \"content_block_start\", \"index\": 0, \""),
    (1000, 6, "error", "error", "Could not parse Anthropic SSE event content_block_delta: Unterminated string in JSON at position 88 (line 1 column 89); data={\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"thinking_delta\", \"thinkin; raw=event: content_block_delta\\ndata: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"thinking_delta\", \"thinkin"),
    (2500, 18, "error", "error", "Anthropic stream ended before message_stop"),
    (5442, 39, "error", "error", "Could not parse Anthropic SSE event message_delta: Unterminated string in JSON at position 98 (line 1 column 99); data={\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"end_turn\", \"stop_sequence\": null}, \"usage\": {\"; raw=event: message_delta\\ndata: {\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"end_turn\", \"stop_sequence\": null}, \"usage\": {\""),
    (5582, 39, "error", "error", "Could not parse Anthropic SSE event message_delta: Unterminated string in JSON at position 238 (line 1 column 239); data={\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"end_turn\", \"stop_sequence\": null}, \"usage\": {\"input_tokens\": 224, \"output_tokens\": 35, \"cache_read_input_tokens\": 0, \"server_tool_use\": {\"web_search_requests\": 0}, \"service_tier\": \"stand; raw=event: message_delta\\ndata: {\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"end_turn\", \"stop_sequence\": null}, \"usage\": {\"input_tokens\": 224, \"output_tokens\": 35, \"cache_read_input_tokens\": 0, \"server_tool_use\": {\"web_search_requests\": 0}, \"service_tier\": \"stand"),
    (5612, 39, "error", "error", "Could not parse Anthropic SSE event message_stop: Unexpected end of JSON input; data=; raw=event: message_stop\\nda"),
    (5640, 39, "done", "stop", nil),
]
private let tools2Truncations: [(cut: Int, events: Int, last: String, stop: String, error: String?)] = [
    (300, 2, "error", "error", "Anthropic stream ended before message_stop"),
    (600, 3, "error", "error", "Could not parse Anthropic SSE event content_block_delta: Expected ':' after property name in JSON at position 60 (line 1 column 61); data={\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\"; raw=event: content_block_delta\\ndata: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\""),
    (900, 5, "error", "error", "Could not parse Anthropic SSE event content_block_delta: Unterminated string in JSON at position 79 (line 1 column 80); data={\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"input_json_delta; raw=event: content_block_delta\\ndata: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"input_json_delta"),
    (1500, 10, "error", "error", "Anthropic stream ended before message_stop"),
    (2200, 15, "error", "error", "Could not parse Anthropic SSE event content_block_delta: Unexpected end of JSON input; data=; raw=event: content_block_delta\\ndat"),
    (2827, 20, "error", "error", "Could not parse Anthropic SSE event message_delta: Unexpected end of JSON input; data=; raw=event: message_delta\\ndata"),
    (3007, 20, "error", "error", "Could not parse Anthropic SSE event message_delta: Unterminated string in JSON at position 178 (line 1 column 179); data={\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"tool_use\", \"stop_sequence\": null}, \"usage\": {\"input_tokens\": 248, \"output_tokens\": 22, \"cache_read_input_tokens\": 0, \"server_t; raw=event: message_delta\\ndata: {\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"tool_use\", \"stop_sequence\": null}, \"usage\": {\"input_tokens\": 248, \"output_tokens\": 22, \"cache_read_input_tokens\": 0, \"server_t"),
    (3087, 20, "error", "error", "Anthropic stream ended before message_stop"),
]

private let abortUpstreamError = "Request was aborted"


// MARK: - Harness

private let replayModel = Model(
    id: "zcode/GLM-5.3-Flash",
    name: "zcode/GLM-5.3-Flash",
    api: "anthropic-messages",
    provider: "anthropic",
    baseUrl: "http://127.0.0.1:3426/pass",
    reasoning: true,
    input: ["text", "image"],
    cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
    contextWindow: 1_000_000,
    maxTokens: 32000
)

private let replayTools = [
    Tool(name: "ls", description: "List files in the workspace directory.",
         parameters: ["type": "object", "properties": ["path": ["type": "string"]]]),
    Tool(name: "read", description: "Read a file in the workspace by relative path.",
         parameters: ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]),
]

private let replaySystemPrompt = "You are a helpful assistant with access to workspace tools."
private let toolsPrompt = "Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."

private func userText(_ text: String) -> Message {
    .user(UserMessage(content: .blocks([.text(TextContent(text: text))]), timestamp: 1))
}

private func toolResult(_ id: String, _ name: String, _ text: String) -> Message {
    .toolResult(ToolResultMessage(toolCallId: id, toolName: name, content: [.text(TextContent(text: text))], isError: false, timestamp: 2))
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [FetchRequest] = []
    func add(_ request: FetchRequest) { lock.lock(); _requests.append(request); lock.unlock() }
    var requests: [FetchRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
}

/// Deterministic SplitMix64 for reproducible chunking.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private enum Chunking: Sendable {
    case whole
    case fixed(Int)
    case random(seed: UInt64)
}

private func chunks(_ data: Data, _ chunking: Chunking) -> [Data] {
    let bytes = [UInt8](data)
    var result: [Data] = []
    var position = 0
    var rng = SplitMix64(state: 0)
    if case .random(let seed) = chunking { rng = SplitMix64(state: seed) }
    while position < bytes.count {
        let size: Int
        switch chunking {
        case .whole: size = bytes.count
        case .fixed(let n): size = n
        case .random: size = Int.random(in: 1...7, using: &rng)
        }
        let end = min(bytes.count, position + size)
        result.append(Data(bytes[position..<end]))
        position = end
    }
    return result
}

/// Fake fetch serving `sse` (optionally truncated). With `hangAfter`, the body stops after that many bytes and
/// waits until the request signal aborts, then fails with the signal's reason (like undici / URLSession).
private func sseFetch(_ sse: String, cut: Int? = nil, chunking: Chunking = .fixed(200), hangAfter: Int? = nil, captured: Captured? = nil) -> FetchFunction {
    { request in
        captured?.add(request)
        var data = Data(sse.utf8)
        if let cut { data = data.prefix(cut) }
        let parts = chunks(hangAfter.map { data.prefix($0) } ?? data, chunking)
        let signal = request.signal
        let body = ResponseBody(AsyncThrowingStream { continuation in
            for part in parts { continuation.yield(part) }
            guard hangAfter != nil else {
                continuation.finish()
                return
            }
            guard let signal else { return }
            let fail: @Sendable () -> Void = { continuation.finish(throwing: signal.reason ?? AbortError()) }
            if signal.aborted { fail() } else { _ = signal.addEventListener(fail) }
        })
        return FetchResponse(status: 200, headers: Headers([("content-type", "text/event-stream")]), body: body)
    }
}

private func replayContext(_ messages: [Message]) -> TranscriptContext {
    normalizeContext(Context(systemPrompt: replaySystemPrompt, messages: messages, tools: replayTools))
}

private struct Replay {
    var events: [AssistantMessageEvent]
    var result: AssistantMessage
    var requests: [FetchRequest]
}

private func replay(
    _ sse: String,
    _ messages: [Message],
    _ reasoning: ThinkingLevel,
    cut: Int? = nil,
    chunking: Chunking = .fixed(200)
) async throws -> Replay {
    let captured = Captured()
    var options = SimpleStreamOptions()
    options.apiKey = "magpie"
    options.reasoning = reasoning
    options.fetch = sseFetch(sse, cut: cut, chunking: chunking, captured: captured)
    let stream = streamSimpleAnthropicMessages(replayModel, replayContext(messages), options)
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    let result = await stream.result()
    return Replay(events: events, result: result, requests: captured.requests)
}

/// Runs `body` with a deadline so a hung stream fails the test instead of the run.
private func withDeadline<T: Sendable>(_ seconds: Double = 10, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        guard let first = try await group.next(), let value = first else {
            group.cancelAll()
            throw PiError("stream did not finish within \(seconds)s")
        }
        group.cancelAll()
        return value
    }
}

private func compactArgs(_ arguments: JsonObject) -> String { JsonValue.object(arguments).serialized() }

private func eventIndex(_ event: AssistantMessageEvent) -> Int? {
    switch event {
    case .textStart(let i, _), .textDelta(let i, _, _), .textEnd(let i, _, _),
         .thinkingStart(let i, _), .thinkingDelta(let i, _, _), .thinkingEnd(let i, _, _),
         .toolcallStart(let i, _), .toolcallDelta(let i, _, _), .toolcallEnd(let i, _, _):
        return i
    default:
        return nil
    }
}

private func eventDelta(_ event: AssistantMessageEvent) -> String? {
    switch event {
    case .textDelta(_, let d, _), .thinkingDelta(_, let d, _), .toolcallDelta(_, let d, _): return d
    default: return nil
    }
}

private func expectEvents(_ actual: [AssistantMessageEvent], _ expected: [ExpectedEvent], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual.map(\.type) == expected.map(\.type), sourceLocation: sourceLocation)
    guard actual.count == expected.count else { return }
    for (event, want) in zip(actual, expected) {
        #expect(eventIndex(event) == want.index, sourceLocation: sourceLocation)
        #expect(eventDelta(event) == want.delta, sourceLocation: sourceLocation)
        if let args = want.args, let index = eventIndex(event), case .toolCall(let call)? = event.message.content[safe: index] {
            #expect(compactArgs(call.arguments) == args, sourceLocation: sourceLocation)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private func contentJson(_ content: [AssistantContent]) -> JsonValue {
    .array(content.map { block -> JsonValue in
        switch block {
        case .text(let text):
            return ["type": "text", "text": .string(text.text)]
        case .thinking(let thinking):
            var object: JsonObject = ["type": "thinking", "thinking": .string(thinking.thinking)]
            if let signature = thinking.thinkingSignature { object["thinkingSignature"] = .string(signature) }
            if let redacted = thinking.redacted { object["redacted"] = .bool(redacted) }
            return .object(object)
        case .toolCall(let call):
            var object: JsonObject = ["type": "toolCall", "id": .string(call.id), "name": .string(call.name), "arguments": .object(call.arguments)]
            if let error = call.argumentsError { object["argumentsError"] = .string(error) }
            return .object(object)
        }
    })
}

private func expectResult(_ actual: AssistantMessage, _ expectedJson: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let expected = try JsonValue.parse(expectedJson)
    #expect(contentJson(actual.content) == expected["content"], sourceLocation: sourceLocation)
    #expect(actual.api == expected["api"]?.stringValue, sourceLocation: sourceLocation)
    #expect(actual.provider == expected["provider"]?.stringValue, sourceLocation: sourceLocation)
    #expect(actual.model == expected["model"]?.stringValue, sourceLocation: sourceLocation)
    #expect(actual.stopReason.rawValue == expected["stopReason"]?.stringValue, sourceLocation: sourceLocation)
    #expect(actual.rawStopReason == expected["rawStopReason"]?.stringValue, sourceLocation: sourceLocation)
    #expect(actual.responseId == expected["responseId"]?.stringValue, sourceLocation: sourceLocation)
    #expect(actual.responseModel == expected["responseModel"]?.stringValue, sourceLocation: sourceLocation)
    #expect(actual.errorMessage == expected["errorMessage"]?.stringValue, sourceLocation: sourceLocation)
    #expect(actual.providerThinkingLevel == expected["providerThinkingLevel"]?.stringValue, sourceLocation: sourceLocation)
    #expect(actual.diagnostics == nil && expected["diagnostics"] == nil, sourceLocation: sourceLocation)
    let usage = try #require(expected["usage"], sourceLocation: sourceLocation)
    #expect(actual.usage.input == usage["input"]?.intValue, sourceLocation: sourceLocation)
    #expect(actual.usage.output == usage["output"]?.intValue, sourceLocation: sourceLocation)
    #expect(actual.usage.cacheRead == usage["cacheRead"]?.intValue, sourceLocation: sourceLocation)
    #expect(actual.usage.cacheWrite == usage["cacheWrite"]?.intValue, sourceLocation: sourceLocation)
    #expect(actual.usage.cacheWrite1h == usage["cacheWrite1h"]?.intValue, sourceLocation: sourceLocation)
    #expect(actual.usage.reasoning == usage["reasoning"]?.intValue, sourceLocation: sourceLocation)
    #expect(actual.usage.totalTokens == usage["totalTokens"]?.intValue, sourceLocation: sourceLocation)
    #expect(actual.usage.cost.total == usage["cost"]?["total"]?.doubleValue, sourceLocation: sourceLocation)
}

private func expectRequest(_ request: FetchRequest?, head: String, body: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let request = try #require(request, sourceLocation: sourceLocation)
    let recordedHead = try JsonValue.parse(head)
    let sentBody = String(decoding: request.body ?? Data(), as: UTF8.self)
    // Field-for-field (and key order): the serialized bodies are byte-identical.
    #expect(sentBody == body, sourceLocation: sourceLocation)
    #expect(try JsonValue.parse(sentBody) == JsonValue.parse(body), sourceLocation: sourceLocation)
    #expect(request.method == "POST", sourceLocation: sourceLocation)
    #expect(request.url.absoluteString == "http://127.0.0.1:3426/pass" + (recordedHead["path"]?.stringValue ?? ""), sourceLocation: sourceLocation)
    let recordedHeaders = try #require(recordedHead["headers"]?.objectValue, sourceLocation: sourceLocation)
    for name in ["anthropic-version", "x-api-key", "accept", "anthropic-dangerous-direct-browser-access", "content-type", "anthropic-beta"] {
        let recorded = recordedHeaders.first { $0.key.lowercased() == name }?.value.stringValue
        #expect(request.headers.get(name) == recorded, "header \(name)", sourceLocation: sourceLocation)
    }
    #expect(request.headers.get("user-agent") == getPiUserAgent(), sourceLocation: sourceLocation)
    #expect(request.headers.get("authorization") == nil, sourceLocation: sourceLocation)
}

// MARK: - Tests

@Suite("anthropic-messages fixture replay")
struct AnthropicMessagesReplayTests {
    @Test("fixtures are embedded verbatim")
    func fixturesVerbatim() {
        #expect(thinkSse.utf8.count == thinkSseByteCount)
        #expect(t1Sse.utf8.count == t1SseByteCount)
        #expect(t2Sse.utf8.count == t2SseByteCount)
        #expect(t3Sse.utf8.count == t3SseByteCount)
    }

    @Test("think: request body, events and final message match upstream")
    func think() async throws {
        let run = try await withDeadline { try await replay(thinkSse, [userText("What is 17*23? Answer with only the number.")], .high) }
        #expect(run.requests.count == 1)
        try expectRequest(run.requests.first, head: thinkRequestHead, body: thinkRequestBody)
        expectEvents(run.events, thinkEvents)
        try expectResult(run.result, thinkResult)
    }

    @Test("tool loop: each turn's request is built from the previous replayed turn")
    func toolLoop() async throws {
        let m1 = [userText(toolsPrompt)]
        let r1 = try await withDeadline { try await replay(t1Sse, m1, .low) }
        try expectRequest(r1.requests.first, head: t1RequestHead, body: t1RequestBody)
        expectEvents(r1.events, t1Events)
        try expectResult(r1.result, t1Result)

        var a1 = r1.result
        a1.timestamp = 3
        let call1 = try #require(a1.content.first?.toolCallContent)
        let m2 = m1 + [.assistant(a1), toolResult(call1.id, "ls", "a.txt\nb.txt")]
        let r2 = try await withDeadline { try await replay(t2Sse, m2, .low) }
        try expectRequest(r2.requests.first, head: t2RequestHead, body: t2RequestBody)
        expectEvents(r2.events, t2Events)
        try expectResult(r2.result, t2Result)

        var a2 = r2.result
        a2.timestamp = 4
        let calls = a2.content.compactMap(\.toolCallContent)
        try #require(calls.count == 2)
        let m3 = m2 + [.assistant(a2), toolResult(calls[0].id, "read", "alpha\n"), toolResult(calls[1].id, "read", "beta\n")]
        let r3 = try await withDeadline { try await replay(t3Sse, m3, .low) }
        try expectRequest(r3.requests.first, head: t3RequestHead, body: t3RequestBody)
        expectEvents(r3.events, t3Events)
        try expectResult(r3.result, t3Result)
    }

    @Test("byte-sized and random 1-7 byte chunking yields identical events and messages")
    func chunking() async throws {
        let cases: [(String, [Message], ThinkingLevel, [ExpectedEvent], String)] = [
            (thinkSse, [userText("x")], .high, thinkEvents, thinkResult),
            (t1Sse, [userText("x")], .low, t1Events, t1Result),
            (t2Sse, [userText("x")], .low, t2Events, t2Result),
            (t3Sse, [userText("x")], .low, t3Events, t3Result),
        ]
        for (sse, messages, level, events, result) in cases {
            for chunking in [Chunking.whole, .fixed(1)] + (1...6).map({ Chunking.random(seed: UInt64($0) * 7919) }) {
                let run = try await withDeadline { try await replay(sse, messages, level, chunking: chunking) }
                expectEvents(run.events, events)
                try expectResult(run.result, result)
            }
        }
    }

    @Test("truncated streams end with upstream's error, never a silent done")
    func truncation() async throws {
        for (sse, level, table) in [(thinkSse, ThinkingLevel.high, thinkTruncations), (t2Sse, .low, tools2Truncations)] {
            for row in table {
                for chunking in [Chunking.fixed(200), .random(seed: UInt64(row.cut) + 1)] {
                    let run = try await withDeadline { try await replay(sse, [userText("x")], level, cut: row.cut, chunking: chunking) }
                    #expect(run.events.count == row.events, "cut \(row.cut)")
                    #expect(run.events.last?.type == row.last, "cut \(row.cut)")
                    #expect(run.result.stopReason.rawValue == row.stop, "cut \(row.cut)")
                    #expect(run.result.errorMessage == row.error, "cut \(row.cut)")
                }
            }
        }
    }

    @Test("every truncation point terminates; only a complete message_stop yields done")
    func truncationSweep() async throws {
        let sse = t2Sse
        let bytes = Array(sse.utf8)
        // The last byte of the message_stop data line: any cut at or after it still carries a complete stream.
        let stopLine = Array("data: {\"type\": \"message_stop\"}".utf8)
        let stopEnd = (0...(bytes.count - stopLine.count)).last { Array(bytes[$0..<($0 + stopLine.count)]) == stopLine }! + stopLine.count
        for cut in stride(from: 0, to: bytes.count, by: 13) + [stopEnd - 1, stopEnd, bytes.count - 1] {
            let run = try await withDeadline { try await replay(sse, [userText("x")], .low, cut: cut, chunking: .random(seed: UInt64(cut))) }
            let last = try #require(run.events.last, "cut \(cut)")
            if cut >= stopEnd {
                #expect(last.type == "done", "cut \(cut)")
            } else {
                #expect(last.type == "error", "cut \(cut)")
                #expect(run.result.stopReason == .error, "cut \(cut)")
                #expect(run.result.errorMessage?.isEmpty == false, "cut \(cut)")
            }
        }
    }

    @Test("aborting mid-stream ends promptly with stopReason aborted")
    func abortMidStream() async throws {
        for chunking in [Chunking.fixed(200), .random(seed: 42)] {
            let controller = AbortController()
            var options = SimpleStreamOptions()
            options.apiKey = "magpie"
            options.reasoning = .high
            options.signal = controller.signal
            options.fetch = sseFetch(thinkSse, chunking: chunking, hangAfter: 1000)
            let stream = streamSimpleAnthropicMessages(replayModel, replayContext([userText("x")]), options)
            let started = Date()
            let collected = try await withDeadline(5) { () -> [AssistantMessageEvent] in
                var events: [AssistantMessageEvent] = []
                for await event in stream {
                    events.append(event)
                    if case .thinkingDelta = event, events.filter({ $0.type == "thinking_delta" }).count == 1 { controller.abort() }
                }
                return events
            }
            let result = await stream.result()
            #expect(Date().timeIntervalSince(started) < 2)
            #expect(collected.first?.type == "start")
            #expect(collected.last?.type == "error")
            #expect(collected.filter { $0.type == "done" }.isEmpty)
            #expect(result.stopReason == .aborted)
            // Upstream reports "Request was aborted" when the abort is seen before the next read; a read already
            // pending fails with the signal's reason.
            #expect(result.errorMessage == abortUpstreamError || result.errorMessage == AbortError().message)
            let thinking = try #require(result.content.first?.thinkingContent)
            #expect(thinking.thinking.hasPrefix("The"))
        }
    }
}
