import Foundation

// Generated from /tmp/pi-live/fixtures/responses-*.{request.json,sse} and the upstream TS run output
// /tmp/pi-live/out/fx-openai-responses-*.jsonl (agent-only fields timestamp, durationMs, thinkingLevel removed).

struct DResponsesFixture: Sendable {
    var requestBody: String
    var sse: String
    var expectedMessage: String
    var expectedUpdateTypes: [String]
}

let responsesFixtures: [String: DResponsesFixture] = [
    "think": DResponsesFixture(
        requestBody: #"""
{"model":"zcode/GLM-5.3-Flash","input":[{"role":"developer","content":"You are a helpful assistant with access to workspace tools."},{"role":"user","content":[{"type":"input_text","text":"What is 17*23? Answer with only the number."}]}],"stream":true,"store":false,"max_output_tokens":32000,"tools":[{"type":"function","name":"ls","description":"List files in the workspace directory.","parameters":{"type":"object","properties":{"path":{"type":"string"}}}},{"type":"function","name":"read","description":"Read a file in the workspace by relative path.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}}],"reasoning":{"effort":"high","summary":"auto"},"include":["reasoning.encrypted_content"]}
"""#,
        sse: #"""
event: response.created
data: {"response":{"created_at":1792562527,"id":"resp_msg_202610211402013d6741f296944220","model":"GLM-5.3-Flash","object":"response","output":[],"parallel_tool_calls":true,"status":"in_progress","tool_choice":"auto","tools":[]},"sequence_number":0,"type":"response.created"}

event: response.in_progress
data: {"response":{"created_at":1792562527,"id":"resp_msg_202610211402013d6741f296944220","model":"GLM-5.3-Flash","object":"response","output":[],"parallel_tool_calls":true,"status":"in_progress","tool_choice":"auto","tools":[]},"sequence_number":1,"type":"response.in_progress"}

event: response.output_item.added
data: {"item":{"id":"rs_18e0761f042ebcc80000002d","status":"in_progress","summary":[],"type":"reasoning"},"output_index":0,"sequence_number":2,"type":"response.output_item.added"}

event: response.reasoning_summary_part.added
data: {"item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"part":{"text":"","type":"summary_text"},"sequence_number":3,"summary_index":0,"type":"response.reasoning_summary_part.added"}

event: response.reasoning_summary_text.delta
data: {"delta":"The","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":4,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" user","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":5,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" wants","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":6,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" ","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":7,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":"17","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":8,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":"*","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":9,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":"23","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":10,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":".","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":11,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" That","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":12,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":"'s","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":13,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" ","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":14,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":"39","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":15,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":"1","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":16,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":".","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":17,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" They","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":18,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" said","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":19,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" answer","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":20,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" with","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":21,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" only","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":22,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" the","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":23,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":" number","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":24,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.delta
data: {"delta":".","item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":25,"summary_index":0,"type":"response.reasoning_summary_text.delta"}

event: response.reasoning_summary_text.done
data: {"item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"sequence_number":26,"summary_index":0,"text":"The user wants 17*23. That's 391. They said answer with only the number.","type":"response.reasoning_summary_text.done"}

event: response.reasoning_summary_part.done
data: {"item_id":"rs_18e0761f042ebcc80000002d","output_index":0,"part":{"text":"The user wants 17*23. That's 391. They said answer with only the number.","type":"summary_text"},"sequence_number":27,"summary_index":0,"type":"response.reasoning_summary_part.done"}

event: response.output_item.done
data: {"item":{"id":"rs_18e0761f042ebcc80000002d","status":"completed","summary":[{"text":"The user wants 17*23. That's 391. They said answer with only the number.","type":"summary_text"}],"type":"reasoning"},"output_index":0,"sequence_number":28,"type":"response.output_item.done"}

event: response.output_item.added
data: {"item":{"content":[],"id":"msg_18e0761f302acee80000002e","role":"assistant","status":"in_progress","type":"message"},"output_index":1,"sequence_number":29,"type":"response.output_item.added"}

event: response.content_part.added
data: {"content_index":0,"item_id":"msg_18e0761f302acee80000002e","output_index":1,"part":{"annotations":[],"logprobs":[],"text":"","type":"output_text"},"sequence_number":30,"type":"response.content_part.added"}

event: response.output_text.delta
data: {"content_index":0,"delta":"39","item_id":"msg_18e0761f302acee80000002e","logprobs":[],"output_index":1,"sequence_number":31,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"1","item_id":"msg_18e0761f302acee80000002e","logprobs":[],"output_index":1,"sequence_number":32,"type":"response.output_text.delta"}

event: response.output_text.done
data: {"content_index":0,"item_id":"msg_18e0761f302acee80000002e","logprobs":[],"output_index":1,"sequence_number":33,"text":"391","type":"response.output_text.done"}

event: response.content_part.done
data: {"content_index":0,"item_id":"msg_18e0761f302acee80000002e","output_index":1,"part":{"annotations":[],"logprobs":[],"text":"391","type":"output_text"},"sequence_number":34,"type":"response.content_part.done"}

event: response.output_item.done
data: {"item":{"content":[{"annotations":[],"logprobs":[],"text":"391","type":"output_text"}],"id":"msg_18e0761f302acee80000002e","role":"assistant","status":"completed","type":"message"},"output_index":1,"sequence_number":35,"type":"response.output_item.done"}

event: response.completed
data: {"response":{"created_at":1792562527,"id":"resp_msg_202610211402013d6741f296944220","incomplete_details":null,"model":"GLM-5.3-Flash","object":"response","output":[{"id":"rs_18e0761f042ebcc80000002d","status":"completed","summary":[{"text":"The user wants 17*23. That's 391. They said answer with only the number.","type":"summary_text"}],"type":"reasoning"},{"content":[{"annotations":[],"logprobs":[],"text":"391","type":"output_text"}],"id":"msg_18e0761f302acee80000002e","role":"assistant","status":"completed","type":"message"}],"parallel_tool_calls":true,"status":"completed","tool_choice":"auto","tools":[],"usage":{"input_tokens":220,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":26,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":246}},"sequence_number":36,"type":"response.completed"}


"""#,
        expectedMessage: #"""
{"role":"assistant","content":[{"type":"thinking","thinking":"The user wants 17*23. That's 391. They said answer with only the number.","thinkingSignature":"{\"id\":\"rs_18e0761f042ebcc80000002d\",\"status\":\"completed\",\"summary\":[{\"text\":\"The user wants 17*23. That's 391. They said answer with only the number.\",\"type\":\"summary_text\"}],\"type\":\"reasoning\"}"},{"type":"text","text":"391","textSignature":"{\"v\":1,\"id\":\"msg_18e0761f302acee80000002e\"}"}],"api":"openai-responses","provider":"openai","model":"zcode/GLM-5.3-Flash","usage":{"input":220,"output":26,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":246,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","responseId":"resp_msg_202610211402013d6741f296944220","rawStopReason":"completed"}
"""#,
        expectedUpdateTypes: ["thinking_start", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_end", "text_start", "text_delta", "text_delta", "text_end"]
    ),
    "tools-1": DResponsesFixture(
        requestBody: #"""
{"model":"zcode/GLM-5.3-Flash","input":[{"role":"developer","content":"You are a helpful assistant with access to workspace tools."},{"role":"user","content":[{"type":"input_text","text":"Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."}]}],"stream":true,"store":false,"max_output_tokens":32000,"tools":[{"type":"function","name":"ls","description":"List files in the workspace directory.","parameters":{"type":"object","properties":{"path":{"type":"string"}}}},{"type":"function","name":"read","description":"Read a file in the workspace by relative path.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}}],"reasoning":{"effort":"low","summary":"auto"},"include":["reasoning.encrypted_content"]}
"""#,
        sse: #"""
event: response.created
data: {"response":{"created_at":1792562532,"id":"resp_msg_20261021140208c5ef063e3d564186","model":"GLM-5.3-Flash","object":"response","output":[],"parallel_tool_calls":true,"status":"in_progress","tool_choice":"auto","tools":[]},"sequence_number":0,"type":"response.created"}

event: response.in_progress
data: {"response":{"created_at":1792562532,"id":"resp_msg_20261021140208c5ef063e3d564186","model":"GLM-5.3-Flash","object":"response","output":[],"parallel_tool_calls":true,"status":"in_progress","tool_choice":"auto","tools":[]},"sequence_number":1,"type":"response.in_progress"}

event: response.output_item.added
data: {"item":{"arguments":"","call_id":"call_4897cdc98eed4d0a96d7b0cd","id":"fc_18e07620471d93280000002f","name":"ls","status":"in_progress","type":"function_call"},"output_index":0,"sequence_number":2,"type":"response.output_item.added"}

event: response.function_call_arguments.delta
data: {"delta":"{\"","item_id":"fc_18e07620471d93280000002f","output_index":0,"sequence_number":3,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"path","item_id":"fc_18e07620471d93280000002f","output_index":0,"sequence_number":4,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"\":\"","item_id":"fc_18e07620471d93280000002f","output_index":0,"sequence_number":5,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":".\"","item_id":"fc_18e07620471d93280000002f","output_index":0,"sequence_number":6,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"}","item_id":"fc_18e07620471d93280000002f","output_index":0,"sequence_number":7,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.done
data: {"arguments":"{\"path\":\".\"}","call_id":"call_4897cdc98eed4d0a96d7b0cd","item_id":"fc_18e07620471d93280000002f","name":"ls","output_index":0,"sequence_number":8,"type":"response.function_call_arguments.done"}

event: response.output_item.done
data: {"item":{"arguments":"{\"path\":\".\"}","call_id":"call_4897cdc98eed4d0a96d7b0cd","id":"fc_18e07620471d93280000002f","name":"ls","status":"completed","type":"function_call"},"output_index":0,"sequence_number":9,"type":"response.output_item.done"}

event: response.completed
data: {"response":{"created_at":1792562532,"id":"resp_msg_20261021140208c5ef063e3d564186","incomplete_details":null,"model":"GLM-5.3-Flash","object":"response","output":[{"arguments":"{\"path\":\".\"}","call_id":"call_4897cdc98eed4d0a96d7b0cd","id":"fc_18e07620471d93280000002f","name":"ls","status":"completed","type":"function_call"}],"parallel_tool_calls":true,"status":"completed","tool_choice":"auto","tools":[],"usage":{"input_tokens":230,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":241}},"sequence_number":10,"type":"response.completed"}


"""#,
        expectedMessage: #"""
{"role":"assistant","content":[{"type":"toolCall","id":"call_4897cdc98eed4d0a96d7b0cd|fc_18e07620471d93280000002f","name":"ls","arguments":{"path":"."}}],"api":"openai-responses","provider":"openai","model":"zcode/GLM-5.3-Flash","usage":{"input":230,"output":11,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":241,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","responseId":"resp_msg_20261021140208c5ef063e3d564186","rawStopReason":"completed"}
"""#,
        expectedUpdateTypes: ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_end"]
    ),
    "tools-2": DResponsesFixture(
        requestBody: #"""
{"model":"zcode/GLM-5.3-Flash","input":[{"role":"developer","content":"You are a helpful assistant with access to workspace tools."},{"role":"user","content":[{"type":"input_text","text":"Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."}]},{"type":"function_call","id":"fc_18e07620471d93280000002f","call_id":"call_4897cdc98eed4d0a96d7b0cd","name":"ls","arguments":"{\"path\":\".\"}"},{"type":"function_call_output","call_id":"call_4897cdc98eed4d0a96d7b0cd","output":"a.txt\nb.txt"}],"stream":true,"store":false,"max_output_tokens":32000,"tools":[{"type":"function","name":"ls","description":"List files in the workspace directory.","parameters":{"type":"object","properties":{"path":{"type":"string"}}}},{"type":"function","name":"read","description":"Read a file in the workspace by relative path.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}}],"reasoning":{"effort":"low","summary":"auto"},"include":["reasoning.encrypted_content"]}
"""#,
        sse: #"""
event: response.created
data: {"response":{"created_at":1792562537,"id":"resp_msg_20261021140212a61f6ba2a275443f","model":"GLM-5.3-Flash","object":"response","output":[],"parallel_tool_calls":true,"status":"in_progress","tool_choice":"auto","tools":[]},"sequence_number":0,"type":"response.created"}

event: response.in_progress
data: {"response":{"created_at":1792562537,"id":"resp_msg_20261021140212a61f6ba2a275443f","model":"GLM-5.3-Flash","object":"response","output":[],"parallel_tool_calls":true,"status":"in_progress","tool_choice":"auto","tools":[]},"sequence_number":1,"type":"response.in_progress"}

event: response.output_item.added
data: {"item":{"arguments":"","call_id":"call_d9a469d4788e4ae5851cd697","id":"fc_18e076216874f49800000030","name":"read","status":"in_progress","type":"function_call"},"output_index":0,"sequence_number":2,"type":"response.output_item.added"}

event: response.function_call_arguments.delta
data: {"delta":"{\"","item_id":"fc_18e076216874f49800000030","output_index":0,"sequence_number":3,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"path","item_id":"fc_18e076216874f49800000030","output_index":0,"sequence_number":4,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"\":\"","item_id":"fc_18e076216874f49800000030","output_index":0,"sequence_number":5,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"a","item_id":"fc_18e076216874f49800000030","output_index":0,"sequence_number":6,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":".txt","item_id":"fc_18e076216874f49800000030","output_index":0,"sequence_number":7,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"\"","item_id":"fc_18e076216874f49800000030","output_index":0,"sequence_number":8,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"}","item_id":"fc_18e076216874f49800000030","output_index":0,"sequence_number":9,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.done
data: {"arguments":"{\"path\":\"a.txt\"}","call_id":"call_d9a469d4788e4ae5851cd697","item_id":"fc_18e076216874f49800000030","name":"read","output_index":0,"sequence_number":10,"type":"response.function_call_arguments.done"}

event: response.output_item.done
data: {"item":{"arguments":"{\"path\":\"a.txt\"}","call_id":"call_d9a469d4788e4ae5851cd697","id":"fc_18e076216874f49800000030","name":"read","status":"completed","type":"function_call"},"output_index":0,"sequence_number":11,"type":"response.output_item.done"}

event: response.output_item.added
data: {"item":{"arguments":"","call_id":"call_9b8b90cc2f1f4ad78b562d4a","id":"fc_18e0762170e2078800000031","name":"read","status":"in_progress","type":"function_call"},"output_index":1,"sequence_number":12,"type":"response.output_item.added"}

event: response.function_call_arguments.delta
data: {"delta":"{\"","item_id":"fc_18e0762170e2078800000031","output_index":1,"sequence_number":13,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"path","item_id":"fc_18e0762170e2078800000031","output_index":1,"sequence_number":14,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"\":\"","item_id":"fc_18e0762170e2078800000031","output_index":1,"sequence_number":15,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"b","item_id":"fc_18e0762170e2078800000031","output_index":1,"sequence_number":16,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":".txt","item_id":"fc_18e0762170e2078800000031","output_index":1,"sequence_number":17,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"\"","item_id":"fc_18e0762170e2078800000031","output_index":1,"sequence_number":18,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"}","item_id":"fc_18e0762170e2078800000031","output_index":1,"sequence_number":19,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.done
data: {"arguments":"{\"path\":\"b.txt\"}","call_id":"call_9b8b90cc2f1f4ad78b562d4a","item_id":"fc_18e0762170e2078800000031","name":"read","output_index":1,"sequence_number":20,"type":"response.function_call_arguments.done"}

event: response.output_item.done
data: {"item":{"arguments":"{\"path\":\"b.txt\"}","call_id":"call_9b8b90cc2f1f4ad78b562d4a","id":"fc_18e0762170e2078800000031","name":"read","status":"completed","type":"function_call"},"output_index":1,"sequence_number":21,"type":"response.output_item.done"}

event: response.completed
data: {"response":{"created_at":1792562537,"id":"resp_msg_20261021140212a61f6ba2a275443f","incomplete_details":null,"model":"GLM-5.3-Flash","object":"response","output":[{"arguments":"{\"path\":\"a.txt\"}","call_id":"call_d9a469d4788e4ae5851cd697","id":"fc_18e076216874f49800000030","name":"read","status":"completed","type":"function_call"},{"arguments":"{\"path\":\"b.txt\"}","call_id":"call_9b8b90cc2f1f4ad78b562d4a","id":"fc_18e0762170e2078800000031","name":"read","status":"completed","type":"function_call"}],"parallel_tool_calls":true,"status":"completed","tool_choice":"auto","tools":[],"usage":{"input_tokens":250,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":22,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":272}},"sequence_number":22,"type":"response.completed"}


"""#,
        expectedMessage: #"""
{"role":"assistant","content":[{"type":"toolCall","id":"call_d9a469d4788e4ae5851cd697|fc_18e076216874f49800000030","name":"read","arguments":{"path":"a.txt"}},{"type":"toolCall","id":"call_9b8b90cc2f1f4ad78b562d4a|fc_18e0762170e2078800000031","name":"read","arguments":{"path":"b.txt"}}],"api":"openai-responses","provider":"openai","model":"zcode/GLM-5.3-Flash","usage":{"input":250,"output":22,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":272,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","responseId":"resp_msg_20261021140212a61f6ba2a275443f","rawStopReason":"completed"}
"""#,
        expectedUpdateTypes: ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_end", "toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_end"]
    ),
    "tools-3": DResponsesFixture(
        requestBody: #"""
{"model":"zcode/GLM-5.3-Flash","input":[{"role":"developer","content":"You are a helpful assistant with access to workspace tools."},{"role":"user","content":[{"type":"input_text","text":"Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."}]},{"type":"function_call","id":"fc_18e07620471d93280000002f","call_id":"call_4897cdc98eed4d0a96d7b0cd","name":"ls","arguments":"{\"path\":\".\"}"},{"type":"function_call_output","call_id":"call_4897cdc98eed4d0a96d7b0cd","output":"a.txt\nb.txt"},{"type":"function_call","id":"fc_18e076216874f49800000030","call_id":"call_d9a469d4788e4ae5851cd697","name":"read","arguments":"{\"path\":\"a.txt\"}"},{"type":"function_call","id":"fc_18e0762170e2078800000031","call_id":"call_9b8b90cc2f1f4ad78b562d4a","name":"read","arguments":"{\"path\":\"b.txt\"}"},{"type":"function_call_output","call_id":"call_d9a469d4788e4ae5851cd697","output":"alpha\n"},{"type":"function_call_output","call_id":"call_9b8b90cc2f1f4ad78b562d4a","output":"beta\n"}],"stream":true,"store":false,"max_output_tokens":32000,"tools":[{"type":"function","name":"ls","description":"List files in the workspace directory.","parameters":{"type":"object","properties":{"path":{"type":"string"}}}},{"type":"function","name":"read","description":"Read a file in the workspace by relative path.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}}],"reasoning":{"effort":"low","summary":"auto"},"include":["reasoning.encrypted_content"]}
"""#,
        sse: #"""
event: response.created
data: {"response":{"created_at":1792562542,"id":"resp_msg_20261021140217c3cb895865d54701","model":"GLM-5.3-Flash","object":"response","output":[],"parallel_tool_calls":true,"status":"in_progress","tool_choice":"auto","tools":[]},"sequence_number":0,"type":"response.created"}

event: response.in_progress
data: {"response":{"created_at":1792562542,"id":"resp_msg_20261021140217c3cb895865d54701","model":"GLM-5.3-Flash","object":"response","output":[],"parallel_tool_calls":true,"status":"in_progress","tool_choice":"auto","tools":[]},"sequence_number":1,"type":"response.in_progress"}

event: response.output_item.added
data: {"item":{"content":[],"id":"msg_18e076228bcb3b1800000032","role":"assistant","status":"in_progress","type":"message"},"output_index":0,"sequence_number":2,"type":"response.output_item.added"}

event: response.content_part.added
data: {"content_index":0,"item_id":"msg_18e076228bcb3b1800000032","output_index":0,"part":{"annotations":[],"logprobs":[],"text":"","type":"output_text"},"sequence_number":3,"type":"response.content_part.added"}

event: response.output_text.delta
data: {"content_index":0,"delta":"The","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":4,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" workspace","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":5,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" contains","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":6,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" two","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":7,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" files","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":8,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":":\n\n","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":9,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"-","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":10,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" **","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":11,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"a","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":12,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":".txt","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":13,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"**:","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":14,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" `","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":15,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"alpha","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":16,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"`\n","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":17,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"-","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":18,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" **","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":19,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"b","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":20,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":".txt","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":21,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"**:","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":22,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" `","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":23,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"beta","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":24,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"`","item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":25,"type":"response.output_text.delta"}

event: response.output_text.done
data: {"content_index":0,"item_id":"msg_18e076228bcb3b1800000032","logprobs":[],"output_index":0,"sequence_number":26,"text":"The workspace contains two files:\n\n- **a.txt**: `alpha`\n- **b.txt**: `beta`","type":"response.output_text.done"}

event: response.content_part.done
data: {"content_index":0,"item_id":"msg_18e076228bcb3b1800000032","output_index":0,"part":{"annotations":[],"logprobs":[],"text":"The workspace contains two files:\n\n- **a.txt**: `alpha`\n- **b.txt**: `beta`","type":"output_text"},"sequence_number":27,"type":"response.content_part.done"}

event: response.output_item.done
data: {"item":{"content":[{"annotations":[],"logprobs":[],"text":"The workspace contains two files:\n\n- **a.txt**: `alpha`\n- **b.txt**: `beta`","type":"output_text"}],"id":"msg_18e076228bcb3b1800000032","role":"assistant","status":"completed","type":"message"},"output_index":0,"sequence_number":28,"type":"response.output_item.done"}

event: response.completed
data: {"response":{"created_at":1792562542,"id":"resp_msg_20261021140217c3cb895865d54701","incomplete_details":null,"model":"GLM-5.3-Flash","object":"response","output":[{"content":[{"annotations":[],"logprobs":[],"text":"The workspace contains two files:\n\n- **a.txt**: `alpha`\n- **b.txt**: `beta`","type":"output_text"}],"id":"msg_18e076228bcb3b1800000032","role":"assistant","status":"completed","type":"message"}],"parallel_tool_calls":true,"status":"completed","tool_choice":"auto","tools":[],"usage":{"input_tokens":282,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":24,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":306}},"sequence_number":29,"type":"response.completed"}


"""#,
        expectedMessage: #"""
{"role":"assistant","content":[{"type":"text","text":"The workspace contains two files:\n\n- **a.txt**: `alpha`\n- **b.txt**: `beta`","textSignature":"{\"v\":1,\"id\":\"msg_18e076228bcb3b1800000032\"}"}],"api":"openai-responses","provider":"openai","model":"zcode/GLM-5.3-Flash","usage":{"input":282,"output":24,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":306,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","responseId":"resp_msg_20261021140217c3cb895865d54701","rawStopReason":"completed"}
"""#,
        expectedUpdateTypes: ["text_start", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_end"]
    ),
]
