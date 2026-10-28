import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-tool-choice.test.ts
// Swift: the upstream `vi.mock("openai")` is replaced by the real SDK talking to a fake fetch
// (`CFakeServer`); `mockState.chunks` become SSE chunks and `payload` is captured via `onPayload`.

private let localOpenAICompletionsModelJSON = #""api":"openai-completions","provider":"local-vllm","baseUrl":"http://localhost:8000/v1","reasoning":true,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":128000,"maxTokens":8192"#

private func localModel(id: String, name: String, extra: String = "") -> Model {
    cModel("{\"id\":\"\(id)\",\"name\":\"\(name)\",\(localOpenAICompletionsModelJSON)\(extra.isEmpty ? "" : "," + extra)}")
}

private let pingTool = Tool(name: "ping", description: "Ping tool", parameters: cObjectSchema([("ok", "boolean")]))

private func captureSimpleParams(_ model: Model, _ reasoning: ThinkingLevel?) async throws -> JsonValue {
    try await cRunSimple(model, cUserContext("Hi")) { $0.reasoning = reasoning }.payload
}

private func compat(_ model: Model, _ key: String) -> JsonValue? { model.compat?[key] }

private func usageChunk(_ prompt: Int, _ completion: Int, cached: Int = 0, reasoning: Int = 0) -> String {
    #"{"prompt_tokens":\#(prompt),"completion_tokens":\#(completion),"prompt_tokens_details":{"cached_tokens":\#(cached)},"completion_tokens_details":{"reasoning_tokens":\#(reasoning)}}"#
}

@Suite("openai-completions tool_choice")
struct OpenAICompletionsToolChoiceTests {
    @Test("forwards toolChoice from simple options to payload")
    func forwardsToolChoice() async throws {
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Call ping with ok=true", tools: [pingTool])) {
            $0.toolChoice = "required"
        }
        #expect(run.payload["tool_choice"] == "required")
        #expect((run.payload["tools"]?.arrayValue?.count ?? 0) > 0)
    }

    @Test("includes toolChoice when no tools are provided")
    func toolChoiceWithoutTools() async throws {
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Summarize the conversation")) { $0.toolChoice = "none" }
        #expect(run.payload["tool_choice"] == "none")
        #expect(run.payload["tools"] == nil)
    }

    @Test("omits strict when compat disables strict mode")
    func omitsStrict() async throws {
        let run = try await cRunSimple(cOpenAICompletionsModel(compat: ["supportsStrictMode": false]), cUserContext("Call ping with ok=true", tools: [pingTool]))
        let tool = try #require(run.payload["tools"]?[0]?["function"])
        #expect(tool["strict"] == nil)
        #expect(!cKeys(tool).contains("strict"))
    }

    @Test("defaults unknown OpenAI-compatible endpoints to non-strict tools")
    func unknownEndpointsNonStrict() async throws {
        // Regression test for #9816.
        let model = localModel(id: "local-model", name: "Local Model")
        let tool = Tool(name: "ping", description: "Ping tool", parameters: cObjectSchema([("required", "string"), ("optional", "string")], optional: ["optional"]),
                        constrainedSampling: .some(.jsonSchema(strict: "prefer")))
        let run = try await cRunSimple(model, cUserContext("Call ping", tools: [tool]))
        let function = run.payload["tools"]?[0]?["function"]
        #expect(!cKeys(function).contains("strict"))
        #expect(function?["parameters"]?["required"] == ["required"])
    }

    @Test("preserves strict tools for capable built-in Chat Completions models")
    func strictForCapableModels() async throws {
        let model = cBuiltin("groq", "openai/gpt-oss-20b")
        #expect(compat(model, "supportsStrictMode") == true)
        let tool = Tool(name: "ping", description: "Ping tool", parameters: cObjectSchema([("required", "string"), ("optional", "string")], optional: ["optional"]),
                        constrainedSampling: .some(.jsonSchema(strict: "prefer")))
        let run = try await cRunSimple(model, cUserContext("Call ping", tools: [tool]))
        let function = run.payload["tools"]?[0]?["function"]
        #expect(function?["strict"] == true)
        #expect(function?["parameters"]?["required"] == ["required", "optional"])
    }

    @Test("maps Groq Qwen reasoning levels to default reasoning_effort")
    func groqQwenReasoning() async throws {
        let run = try await cRunSimple(cBuiltin("groq", "qwen/qwen3.6-27b"), cUserContext()) { $0.reasoning = .medium }
        #expect(run.payload["reasoning_effort"] == "default")
    }

    @Test("keeps normal reasoning_effort for groq models without compat mapping")
    func groqNormalReasoning() async throws {
        let run = try await cRunSimple(cBuiltin("groq", "openai/gpt-oss-20b"), cUserContext()) { $0.reasoning = .medium }
        #expect(run.payload["reasoning_effort"] == "medium")
    }

    @Test("enables tool_stream for supported z.ai models with tools")
    func zaiToolStream() async throws {
        let run = try await cRunSimple(cBuiltin("zai", "glm-5.2"), cUserContext("Call ping with ok=true", tools: [pingTool]))
        #expect(run.payload["tool_stream"] == true)
    }

    @Test("stores z.ai tool_stream support in model compat metadata")
    func zaiToolStreamMetadata() {
        for id in ["glm-4.7", "glm-4.7", "glm-5-turbo", "glm-5.2"] {
            #expect(compat(cBuiltin("zai", id), "zaiToolStream") == true, "\(id)")
        }
    }

    @Test("stores z.ai effort metadata")
    func zaiEffortMetadata() {
        for id in ["glm-5.2", "glm-5.2-highspeed"] {
            let model = cBuiltin("zai", id)
            #expect(compat(model, "supportsReasoningEffort") == true)
            #expect(model.thinkingLevelMap.map(thinkingLevelMapToJson).map(canonicalLevels) == canonicalLevels(cJSON(#"{"off":"none","minimal":null,"low":null,"medium":null,"high":"high","xhigh":null,"max":"max"}"#)))
        }
        for provider in ["zai", "zai-coding-cn"] {
            let glm53 = cBuiltin(provider, "glm-5.3")
            #expect(compat(glm53, "supportsReasoningEffort") == true)
            #expect(glm53.thinkingLevelMap.map(thinkingLevelMapToJson).map(canonicalLevels) == canonicalLevels(cJSON(#"{"off":null,"minimal":null,"low":"low","medium":null,"high":"high","xhigh":null,"max":"max"}"#)))
        }
    }

    @Test("maps z.ai GLM-5.2 thinking levels to reasoning_effort")
    func zaiThinkingLevels() async throws {
        let model = cBuiltin("zai", "glm-5.2")
        for (reasoning, effort) in [(ThinkingLevel.low, "high"), (.medium, "high"), (.high, "high"), (.max, "max")] {
            let run = try await cRunSimple(model, cUserContext()) { $0.reasoning = reasoning }
            #expect(run.payload["thinking"] == cJSON(#"{"type":"enabled","clear_thinking":false}"#))
            #expect(run.payload["reasoning_effort"] == .string(effort))
        }
    }

    @Test("preserves z.ai thinking when replaying reasoning_content")
    func zaiReplayReasoningContent() async throws {
        let model = cBuiltin("zai", "glm-5.2")
        let messages = cMessages(#"""
        [{"role":"user","content":"Read README.md"},
         {"role":"assistant","api":"openai-completions","provider":"zai","model":"glm-5.2","content":[{"type":"thinking","thinking":"prior reasoning","thinkingSignature":"reasoning_content"},{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"README.md"}}],"stopReason":"toolUse"},
         {"role":"toolResult","toolCallId":"call_1","toolName":"read","content":[{"type":"text","text":"contents"}],"isError":false},
         {"role":"user","content":"Continue"}]
        """#)
        let run = try await cRunSimple(model, Context(messages: messages)) { $0.reasoning = .high }
        let replayed = run.payload["messages"]?.arrayValue?.first { $0["role"] == "assistant" }
        #expect(cMatches(replayed, ["reasoning_content": "prior reasoning"]))
        #expect(run.payload["thinking"] == cJSON(#"{"type":"enabled","clear_thinking":false}"#))
    }

    @Test("omits z.ai GLM-5.2 reasoning_effort when thinking is off")
    func zaiThinkingOff() async throws {
        let run = try await cRunSimple(cBuiltin("zai", "glm-5.2"), cUserContext())
        #expect(run.payload["thinking"] == cJSON(#"{"type":"disabled"}"#))
        #expect(run.payload["reasoning_effort"] == nil)
    }

    @Test("respects explicit z.ai tool_stream compat override")
    func zaiToolStreamOverride() async throws {
        var model = cBuiltin("zai", "glm-5.2")
        var compatObject = model.compat ?? JsonObject()
        compatObject["zaiToolStream"] = true
        model.compat = compatObject
        let run = try await cRunSimple(model, cUserContext("Call ping with ok=true", tools: [pingTool]))
        #expect(run.payload["tool_stream"] == true)
    }

    @Test("omits tool_stream when no tools are provided")
    func zaiNoToolStreamWithoutTools() async throws {
        let run = try await cRunSimple(cBuiltin("zai", "glm-5.2"), cUserContext())
        #expect(run.payload["tool_stream"] == nil)
    }

    @Test("maps non-standard provider finish_reason values to stopReason error")
    func nonStandardFinishReason() async throws {
        let run = try await cRunSimple(cBuiltin("zai", "glm-5.2"), cUserContext(), chunks: [
            cJSON(#"{"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#),
            cJSON(#"{"choices":[{"delta":{},"finish_reason":"network_error"}],"usage":\#(usageChunk(1, 1))}"#),
        ])
        #expect(run.result.stopReason == .error)
        #expect(run.result.errorMessage == "Provider finish_reason: network_error")
    }

    @Test("ignores null stream chunks from openai-compatible providers")
    func ignoresNullChunks() async throws {
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Reply with exactly OK"), chunks: [
            .null,
            cJSON(#"{"id":"chatcmpl-test","choices":[{"delta":{"content":"OK"},"finish_reason":null}]}"#),
            cJSON(#"{"id":"chatcmpl-test","choices":[{"delta":{},"finish_reason":"stop"}],"usage":\#(usageChunk(3, 1))}"#),
        ])
        #expect(run.result.stopReason == .stop)
        #expect(run.result.errorMessage == nil)
        #expect(run.result.responseId == "chatcmpl-test")
        #expect(run.result.usage.totalTokens == 4)
        #expect(cContentJSON(run.result) == cJSON(#"[{"type":"text","text":"OK"}]"#))
    }

    @Test("errors when a stream ends after only null finish_reason chunks")
    func errorsWithoutFinishReason() async throws {
        let chunk = cJSON(#"{"id":"chatcmpl-truncated","choices":[{"delta":{"content":"partial answer"},"finish_reason":null}]}"#)
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Reply with a longer sentence"), chunks: [chunk, chunk])
        #expect(run.result.stopReason == .error)
        #expect(run.result.errorMessage == "Stream ended without finish_reason")
    }

    @Test("accepts streams without finish_reason when compat disables it")
    func acceptsWithoutFinishReason() async throws {
        let run = try await cRunSimple(cOpenAICompletionsModel(compat: ["supportsFinishReason": false]), cUserContext("Reply with a complete answer"), chunks: [
            cJSON(#"{"id":"chatcmpl-no-finish-reason","choices":[{"delta":{"content":"complete answer"},"finish_reason":null}]}"#),
        ])
        #expect(run.result.stopReason == .stop)
        #expect(run.result.errorMessage == nil)
        #expect(cContentJSON(run.result) == cJSON(#"[{"type":"text","text":"complete answer"}]"#))
    }

    @Test("ignores empty custom objects on function tool call deltas")
    func ignoresEmptyCustom() async throws {
        let tool = Tool(name: "read", description: "Read a file", parameters: cObjectSchema([("path", "string")]))
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Read README.md", tools: [tool]), chunks: [
            cJSON(#"{"id":"chatcmpl-empty-custom","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":"{\"path\":\"README.md\"}"},"custom":{}}]},"finish_reason":"tool_calls"}]}"#),
        ])
        #expect(cContentJSON(run.result) == cJSON(#"[{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"README.md"}}]"#))
    }

    @Test("coalesces tool call deltas by stable index when provider mutates ids mid-stream")
    func coalescesByIndex() async throws {
        let tool = Tool(name: "read", description: "Read a file", parameters: cObjectSchema([("path", "string")]))
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Read README.md", tools: [tool]), chunks: [
            cJSON(#"{"id":"chatcmpl-kimi-bad-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"functions.read:0","type":"function","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}"#),
            cJSON(#"{"id":"chatcmpl-kimi-bad-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"chatcmpl-tool-a","type":"function","function":{"name":null,"arguments":"{\"path\":\"README"}}]},"finish_reason":null}]}"#),
            cJSON(#"{"id":"chatcmpl-kimi-bad-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"chatcmpl-tool-b","type":"function","function":{"name":null,"arguments":".md\"}"}}]},"finish_reason":"tool_calls"}],"usage":\#(usageChunk(10, 5))}"#),
        ])
        let indexes = run.events.filter { $0.type.hasPrefix("toolcall_") }.compactMap(cContentIndex)
        #expect(run.result.stopReason == .toolUse)
        #expect(indexes == [0, 0, 0, 0, 0])
        #expect(cContentJSON(run.result) == cJSON(#"[{"type":"toolCall","id":"functions.read:0","name":"read","arguments":{"path":"README.md"}}]"#))
    }

    @Test("accumulates mixed content, reasoning, and parallel tool call deltas independently")
    func accumulatesMixedDeltas() async throws {
        let tools = [
            Tool(name: "read", description: "Read a file", parameters: cObjectSchema([("path", "string")])),
            Tool(name: "grep", description: "Search a file", parameters: cObjectSchema([("pattern", "string"), ("path", "string")])),
            Tool(name: "list", description: "List a directory", parameters: cObjectSchema([("path", "string")])),
            Tool(name: "write", description: "Write a file", parameters: cObjectSchema([("path", "string"), ("content", "string")])),
        ]
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Think, answer, and use tools.", tools: tools), chunks: [
            cJSON(#"""
            {"id":"chatcmpl-mixed-deltas","choices":[{"delta":{"content":"answer 1","reasoning_content":"think 1","tool_calls":[
              {"index":0,"id":"tc_read_initial","type":"function","function":{"name":"read","arguments":"{\"path\":\"README"}},
              {"index":1,"id":"tc_grep_initial","type":"function","function":{"name":"grep","arguments":"{\"pattern\":\"TODO"}},
              {"id":"tc_list_no_index","type":"function","function":{"name":"list","arguments":"{\"path\":\"packages"}},
              {"id":"tc_write_no_index","type":"function","function":{"name":"write","arguments":"{\"path\":\"out"}}]},"finish_reason":null}]}
            """#),
            cJSON(#"""
            {"id":"chatcmpl-mixed-deltas","choices":[{"delta":{"content":" answer 2","tool_calls":[
              {"index":1,"id":"tc_grep_changed","type":"function","function":{"arguments":"\",\"path\":\"src"}},
              {"id":"tc_write_no_index","type":"function","function":{"arguments":".txt\",\"content\":\"ok\"}"}},
              {"id":"tc_list_no_index","type":"function","function":{"arguments":"/ai\"}"}}]},"finish_reason":null}]}
            """#),
            cJSON(#"""
            {"id":"chatcmpl-mixed-deltas","choices":[{"delta":{"content":"\n","reasoning_content":" think 2","tool_calls":[
              {"index":0,"id":"tc_read_changed","type":"function","function":{"arguments":".md\"}"}},
              {"index":1,"type":"function","function":{"arguments":"\"}"}}]},"finish_reason":"tool_calls"}],
             "usage":{"prompt_tokens":10,"completion_tokens":8,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":2}}}
            """#),
        ])
        let types = run.events.map(\.type)
        func count(_ type: String) -> Int { types.filter { $0 == type }.count }
        var byIndex: [Int: [String]] = [:]
        for event in run.events where event.type.hasPrefix("toolcall_") {
            byIndex[cContentIndex(event)!, default: []].append(event.type)
        }

        #expect(run.result.stopReason == .toolUse)
        #expect(count("text_start") == 1)
        #expect(count("text_delta") == 3)
        #expect(count("text_end") == 1)
        #expect(count("thinking_start") == 1)
        #expect(count("thinking_delta") == 2)
        #expect(count("thinking_end") == 1)
        #expect(count("toolcall_start") == 4)
        #expect(count("toolcall_delta") == 9)
        #expect(count("toolcall_end") == 4)
        #expect(byIndex[2] == ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_end"])
        #expect(byIndex[3] == ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_end"])
        #expect(byIndex[4] == ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_end"])
        #expect(byIndex[5] == ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_end"])

        #expect(cContentJSON(run.result) == cJSON(#"""
        [{"type":"thinking","thinking":"think 1 think 2","thinkingSignature":"reasoning_content"},
         {"type":"text","text":"answer 1 answer 2\n"},
         {"type":"toolCall","id":"tc_read_initial","name":"read","arguments":{"path":"README.md"}},
         {"type":"toolCall","id":"tc_grep_initial","name":"grep","arguments":{"pattern":"TODO","path":"src"}},
         {"type":"toolCall","id":"tc_list_no_index","name":"list","arguments":{"path":"packages/ai"}},
         {"type":"toolCall","id":"tc_write_no_index","name":"write","arguments":{"path":"out.txt","content":"ok"}}]
        """#))
    }

    @Test("uses system messages for non-OpenAI/Anthropic OpenRouter reasoning model instructions")
    func openRouterSystemRole() async throws {
        let run = try await cRunSimple(cBuiltin("openrouter", "deepseek/deepseek-v4-pro"), cUserContext(systemPrompt: "Follow instructions."))
        #expect(run.payload["messages"]?[0]?["role"] == "system")
    }

    @Test("keeps developer messages for OpenAI and Anthropic OpenRouter batch instructions")
    func openRouterDeveloperRole() async throws {
        for id in ["openai/gpt-5.2-codex", "anthropic/claude-fable-5.1:batch"] {
            let run = try await cRunSimple(cBuiltin("openrouter", id), cUserContext(systemPrompt: "Follow instructions."))
            #expect(run.payload["messages"]?[0]?["role"] == "developer", "\(id)")
        }
    }

    @Test("keeps developer messages for OpenAI reasoning model instructions")
    func openAIDeveloperRole() async throws {
        var model = cBuiltin("openai", "gpt-5.5")
        model.compat = nil
        model.api = "openai-completions"
        let run = try await cRunSimple(model, cUserContext(systemPrompt: "Follow instructions."))
        #expect(run.payload["messages"]?[0]?["role"] == "developer")
    }

    @Test("stores OpenRouter Kimi K2.6 reasoning replay compat in built-in metadata")
    func openRouterKimiMetadata() {
        let model = cBuiltin("openrouter", "moonshotai/kimi-k2.6")
        #expect(compat(model, "supportsDeveloperRole") == false)
        #expect(compat(model, "requiresReasoningContentOnAssistantMessages") == true)
    }

    @Test("stores Xiaomi MiMo reasoning replay compat in built-in metadata")
    func xiaomiMetadata() {
        for provider in ["xiaomi", "xiaomi-token-plan-cn", "xiaomi-token-plan-ams", "xiaomi-token-plan-sgp"] {
            let model = cBuiltin(provider, "mimo-v2.6-pro")
            #expect(compat(model, "requiresReasoningContentOnAssistantMessages") == true)
            #expect(compat(model, "thinkingFormat") == "deepseek")
            #expect(compat(model, "maxTokensField") == nil)
            #expect(compat(model, "supportsDeveloperRole") == nil)
        }
    }

    @Test("stores Qwen Token Plan reasoning replay compat in built-in metadata")
    func qwenTokenPlanMetadata() {
        for provider in ["qwen-token-plan", "qwen-token-plan-cn", "qwen-token-plan-individual"] {
            let model = cBuiltin(provider, "qwen3.7-max")
            #expect(compat(model, "thinkingFormat") == "qwen")
            #expect(compat(model, "requiresReasoningContentOnAssistantMessages") == nil)
            #expect(compat(model, "supportsDeveloperRole") == false)
            #expect(compat(model, "supportsStore") == false)
        }
    }

    @Test("replays Xiaomi MiMo assistant tool calls with empty reasoning_content when thinking is missing")
    func xiaomiEmptyReasoningContent() async throws {
        let messages = cMessages(#"""
        [{"role":"user","content":"Read README.md"},
         {"role":"assistant","api":"openai-completions","provider":"xiaomi","model":"mimo-v2.6-pro","content":[{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"README.md"}}],"stopReason":"toolUse"},
         {"role":"toolResult","toolCallId":"call_1","toolName":"read","content":[{"type":"text","text":"contents"}],"isError":false}]
        """#)
        let run = try await cRunSimple(cBuiltin("xiaomi", "mimo-v2.6-pro"), Context(messages: messages)) { $0.reasoning = .high }
        let replayed = run.payload["messages"]?.arrayValue?.first { $0["role"] == "assistant" }
        #expect(cMatches(replayed, ["role": "assistant", "reasoning_content": ""]))
        #expect(run.payload["thinking"] == cJSON(#"{"type":"enabled"}"#))
        #expect(run.payload["reasoning_effort"] == nil)
    }

    @Test("normalizes OpenCode Go reasoning deltas to reasoning_content for replay")
    func openCodeGoReasoning() async throws {
        var model = cBuiltin("opencode-go", "kimi-k3")
        model.compat = nil
        model.api = "openai-completions"
        let run = try await cRunSimple(model, cUserContext("Use reasoning."), chunks: [
            cJSON(#"{"id":"chatcmpl-opencode-go-reasoning","choices":[{"delta":{"reasoning":"think"},"finish_reason":"stop"}]}"#),
        ])
        #expect(cContentJSON(run.result) == cJSON(#"[{"type":"thinking","thinking":"think","thinkingSignature":"reasoning_content"}]"#))
    }

    @Test("keeps non-OpenCode Go reasoning deltas on the original reasoning field")
    func nonOpenCodeGoReasoning() async throws {
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Use reasoning."), chunks: [
            cJSON(#"{"id":"chatcmpl-reasoning","choices":[{"delta":{"reasoning":"think"},"finish_reason":"stop"}]}"#),
        ])
        #expect(cContentJSON(run.result) == cJSON(#"[{"type":"thinking","thinking":"think","thinkingSignature":"reasoning"}]"#))
    }

    @Test("replays OpenCode Go reasoning thinking blocks as reasoning_content")
    func openCodeGoReplay() throws {
        var model = cBuiltin("opencode-go", "kimi-k3")
        model.compat = nil
        model.api = "openai-completions"
        let context = normalizeContext(Context(messages: cMessages(#"""
        [{"role":"assistant","api":"openai-completions","provider":"opencode-go","model":"kimi-k3","content":[{"type":"thinking","thinking":"think","thinkingSignature":"reasoning"},{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"README.md"}}],"stopReason":"stop"}]
        """#)))
        let compat = ResolvedOpenAICompletionsCompat(
            supportsStore: false, supportsDeveloperRole: false, supportsReasoningEffort: true, supportsUsageInStreaming: true,
            supportsFinishReason: true, maxTokensField: .maxCompletionTokens, requiresToolResultName: false,
            requiresAssistantAfterToolResult: false, requiresThinkingAsText: false, requiresReasoningContentOnAssistantMessages: false,
            thinkingFormat: .openai, zaiToolStream: false, supportsStrictMode: true, supportsOpenAIGrammarTools: false,
            sendSessionAffinityHeaders: false, sessionAffinityFormat: .openai, supportsLongCacheRetention: true
        )
        let messages = try convertMessages(model, context, compat)
        #expect(cMatches(.object(messages[0]), ["role": "assistant", "reasoning_content": "think"]))
        #expect(messages[0]["reasoning"] == nil)
    }

    @Test("sends thinking disabled for OpenCode Kimi K2.6 when thinking is off")
    func openCodeKimiOff() async throws {
        let run = try await cRunSimple(cBuiltin("opencode", "kimi-k2.6"), cUserContext())
        #expect(run.payload["thinking"] == cJSON(#"{"type":"disabled"}"#))
        #expect(run.payload["reasoning_effort"] == nil)
    }

    @Test("sends thinking enabled for OpenCode Kimi K2.6 when thinking is enabled")
    func openCodeKimiOn() async throws {
        let run = try await cRunSimple(cBuiltin("opencode", "kimi-k2.6"), cUserContext()) { $0.reasoning = .high }
        #expect(run.payload["thinking"] == cJSON(#"{"type":"enabled"}"#))
        #expect(run.payload["reasoning_effort"] == nil)
    }

    @Test("omits disabled thinking for Moonshot Kimi K2.7 Code models")
    func moonshotKimiCode() async throws {
        for provider in ["moonshotai", "moonshotai-cn"] {
            let run = try await cRunSimple(cBuiltin(provider, "kimi-k2.7-code"), cUserContext())
            #expect(run.payload["thinking"] == nil, "\(provider)")
            #expect(run.payload["reasoning_effort"] == nil, "\(provider)")
        }
    }

    @Test("keeps disabled thinking for Moonshot Kimi K2.6 when thinking is off")
    func moonshotKimiOff() async throws {
        let run = try await cRunSimple(cBuiltin("moonshotai-cn", "kimi-k2.6"), cUserContext())
        #expect(run.payload["thinking"] == cJSON(#"{"type":"disabled"}"#))
        #expect(run.payload["reasoning_effort"] == nil)
    }

    @Test("sends max_tokens for OpenCode completions models")
    func openCodeMaxTokens() async throws {
        for model in [cBuiltin("opencode-go", "kimi-k3"), cBuiltin("opencode", "kimi-k2.6")] {
            #expect(compat(model, "maxTokensField") == "max_tokens")
            let run = try await cRunSimple(model, cUserContext()) { $0.maxTokens = 123 }
            #expect(run.payload["max_tokens"] == 123)
            #expect(run.payload["max_completion_tokens"] == nil)
        }
    }

    @Test("sends max_tokens for built-in and custom DeepSeek API models")
    func deepSeekMaxTokens() async throws {
        let custom = cModel(#"{"id":"custom-deepseek-model","name":"Custom DeepSeek Model",\#(localOpenAICompletionsModelJSON)}"#)
        var customModel = custom
        customModel.provider = "custom-deepseek"
        customModel.baseUrl = "https://api.deepseek.com"
        var customUppercase = customModel
        customUppercase.id = "custom-uppercase-deepseek-model"
        customUppercase.name = "Custom Uppercase DeepSeek Model"
        customUppercase.baseUrl = "https://API.DeepSeek.COM"
        let native = [cBuiltin("deepseek", "deepseek-flash"), cBuiltin("deepseek", "deepseek-v4-pro")]
        for model in native { #expect(compat(model, "maxTokensField") == "max_tokens") }
        for model in native + [customModel, customUppercase] {
            let run = try await cRunSimple(model, cUserContext()) { $0.maxTokens = 123 }
            #expect(run.payload["max_tokens"] == 123, "\(model.id)")
            #expect(run.payload["max_completion_tokens"] == nil, "\(model.id)")
        }
    }

    @Test("sends max_tokens for Z.AI completions models")
    func zaiMaxTokens() async throws {
        for model in [cBuiltin("zai", "glm-5-turbo"), cBuiltin("zai", "glm-5.2")] {
            #expect(compat(model, "maxTokensField") == "max_tokens")
            let run = try await cRunSimple(model, cUserContext()) { $0.maxTokens = 123 }
            #expect(run.payload["max_tokens"] == 123)
            #expect(run.payload["max_completion_tokens"] == nil)
        }
    }

    @Test("omits reasoning effort for OpenCode Grok Build")
    func openCodeGrokBuild() async throws {
        let run = try await cRunSimple(cBuiltin("opencode", "grok-build-0.1"), cUserContext()) { $0.reasoning = .high }
        #expect(run.payload["reasoning_effort"] == nil)
    }

    @Test("does not double-count reasoning tokens in completion usage")
    func reasoningTokensNotDoubleCounted() async throws {
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Use reasoning."), chunks: [
            cJSON(#"{"id":"chatcmpl-reasoning-usage","choices":[{"delta":{},"finish_reason":"stop"}],"usage":\#(usageChunk(10, 33, reasoning: 21))}"#),
        ])
        #expect(run.result.usage.input == 10)
        #expect(run.result.usage.output == 33)
        #expect(run.result.usage.totalTokens == 43)
    }

    @Test("preserves prompt_tokens_details cache read/write fields from chunk usage")
    func cacheFieldsFromChunkUsage() async throws {
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Reply with exactly OK"), chunks: [
            cJSON(#"{"id":"chatcmpl-cache-write","choices":[{"delta":{"content":"OK"},"finish_reason":null}]}"#),
            cJSON(#"{"id":"chatcmpl-cache-write","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":50,"cache_write_tokens":30},"completion_tokens_details":{"reasoning_tokens":0}}}"#),
        ])
        // cached_tokens is documented as cache reads; cache_write_tokens is separate.
        #expect(run.result.usage.input == 20)
        #expect(run.result.usage.cacheRead == 50)
        #expect(run.result.usage.cacheWrite == 30)
        #expect(run.result.usage.totalTokens == 105)
    }

    @Test("preserves prompt_tokens_details cache read/write fields from choice usage fallback")
    func cacheFieldsFromChoiceUsage() async throws {
        let run = try await cRunSimple(cOpenAICompletionsModel(), cUserContext("Reply with exactly OK"), chunks: [
            cJSON(#"{"id":"chatcmpl-cache-write-choice","choices":[{"delta":{"content":"OK"},"finish_reason":null}]}"#),
            cJSON(#"{"id":"chatcmpl-cache-write-choice","choices":[{"delta":{},"finish_reason":"stop","usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":50,"cache_write_tokens":30},"completion_tokens_details":{"reasoning_tokens":0}}}]}"#),
        ])
        #expect(run.result.usage.input == 20)
        #expect(run.result.usage.cacheRead == 50)
        #expect(run.result.usage.cacheWrite == 30)
        #expect(run.result.usage.totalTokens == 105)
    }

    @Test("uses OpenRouter reasoning object instead of reasoning_effort")
    func openRouterReasoningObject() async throws {
        let run = try await cRunSimple(cBuiltin("openrouter", "deepseek/deepseek-r1-0528"), cUserContext()) { $0.reasoning = .high }
        #expect(run.payload["reasoning"] == cJSON(#"{"effort":"high"}"#))
        #expect(run.payload["reasoning_effort"] == nil)
    }

    @Test("uses configurable chat template boolean thinking kwargs")
    func chatTemplateBoolean() async throws {
        let model = localModel(id: "deepseek-ai/DeepSeek-V3.1", name: "DeepSeek V3.1 via vLLM",
                               extra: #""compat":{"thinkingFormat":"chat-template","supportsReasoningEffort":false,"chatTemplateKwargs":{"thinking":{"$var":"thinking.enabled"}}}"#)
        for (reasoning, expected) in [(ThinkingLevel?.some(.high), true), (nil, false)] {
            let params = try await captureSimpleParams(model, reasoning)
            #expect(params["chat_template_kwargs"] == ["thinking": .bool(expected)])
            #expect(params["thinking"] == nil)
            #expect(params["reasoning_effort"] == nil)
        }
    }

    @Test("uses qwen chat template thinking kwargs")
    func qwenChatTemplate() async throws {
        let model = localModel(id: "Qwen/Qwen3-Coder", name: "Qwen3 Coder via vLLM",
                               extra: #""compat":{"thinkingFormat":"qwen-chat-template","supportsReasoningEffort":false}"#)
        for (reasoning, expected) in [(ThinkingLevel?.some(.high), true), (nil, false)] {
            let params = try await captureSimpleParams(model, reasoning)
            #expect(params["chat_template_kwargs"] == ["enable_thinking": .bool(expected), "preserve_thinking": true])
            #expect(params["reasoning_effort"] == nil)
        }
    }

    @Test("uses configurable chat template effort kwargs with static kwargs")
    func chatTemplateEffort() async throws {
        let model = localModel(id: "unsloth/gpt-oss-120b-GGUF", name: "GPT OSS via vLLM",
                               extra: #""thinkingLevelMap":{"xhigh":"max"},"compat":{"thinkingFormat":"chat-template","supportsReasoningEffort":false,"chatTemplateKwargs":{"preserve_thinking":true,"reasoning_effort":{"$var":"thinking.effort","omitWhenOff":true}}}"#)
        let params = try await captureSimpleParams(model, .xhigh)
        #expect(params["chat_template_kwargs"] == ["preserve_thinking": true, "reasoning_effort": "max"])
        #expect(params["reasoning_effort"] == nil)
    }

    @Test("uses Ant Ling compatibility metadata")
    func antLing() async throws {
        let model = cBuiltin("ant-ling", "Ring-2.6-1T")
        #expect(cMatches(model.compat.map(JsonValue.object), cJSON(#"{"supportsStore":false,"supportsDeveloperRole":false,"supportsReasoningEffort":false,"maxTokensField":"max_tokens","thinkingFormat":"ant-ling","supportsLongCacheRetention":false}"#)))
        #expect(compat(model, "supportsStrictMode") == true)
        #expect(compat(model, "requiresReasoningContentOnAssistantMessages") == nil)

        let run = try await cRunSimple(model, cUserContext(systemPrompt: "Follow instructions.")) {
            $0.maxTokens = 123
            $0.reasoning = .high
            $0.cacheRetention = .long
            $0.sessionId = "ant-ling-session"
        }
        let params = run.payload
        #expect(params["max_tokens"] == 123)
        #expect(params["max_completion_tokens"] == nil)
        #expect(params["messages"]?[0]?["role"] == "system")
        #expect(params["reasoning"] == cJSON(#"{"effort":"high"}"#))
        #expect(params["reasoning_effort"] == nil)
        #expect(params["store"] == nil)
        #expect(params["prompt_cache_key"] == nil)
        #expect(params["prompt_cache_retention"] == nil)
    }

    @Test("omits Ant Ling reasoning for unmapped direct reasoning efforts and non-reasoning models")
    func antLingUnmapped() async throws {
        let ring = cBuiltin("ant-ling", "Ring-2.6-1T")
        let direct = try await cRunStream(ring, cUserContext()) { $0.extra["reasoningEffort"] = "medium" }
        #expect(!cKeys(direct.payload).contains("reasoning"))

        let ling = cBuiltin("ant-ling", "Ling-2.6-flash")
        let simple = try await cRunSimple(ling, cUserContext()) { $0.reasoning = .high }
        #expect(!cKeys(simple.payload).contains("reasoning"))
    }
}

/// Thinking level maps compared without key order (upstream `toEqual`).
private func canonicalLevels(_ value: JsonValue) -> [String: JsonValue] {
    var result: [String: JsonValue] = [:]
    for (key, value) in value.objectValue ?? JsonObject() { result[key] = value }
    return result
}
