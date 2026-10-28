import Foundation
import Testing
@testable import PiAI

// Port of the Chat Completions part of packages/ai/test/tool-call-id-normalization.test.ts.
// Upstream runs these against live OpenRouter / Copilot / Codex (skipped without credentials). Swift
// runs the OpenRouter prefilled-context case offline: the real SDK sends to a fake fetch and the test
// checks the replayed ids the live endpoint would have validated (OpenAI's 40-char, [A-Za-z0-9_-] limit).
// The Responses-API cases (github-copilot, openai-codex) belong to the openai-responses port.

private let failingToolCallId =
    "call_pAYbIr76hXIjncD9UE4eGfnS|t5nnb2qYMFWGSsr13fhCd1CaCu3t3qONEPuOudu4HSVEtA8YJSL6FAZUxvoOoD792VIJWl91g87EdqsCWp9krVsdBysQoDaf9lMCLb8BS4EYi4gQd5kBQBYLlgD71PYwvf+TbMD9J9/5OMD42oxSRj8H+vRf78/l2Xla33LWz4nOgsddBlbvabICRs8GHt5C9PK5keFtzyi3lsyVKNlfduK3iphsZqs4MLv4zyGJnvZo/+QzShyk5xnMSQX/f98+aEoNflEApCdEOXipipgeiNWnpFSHbcwmMkZoJhURNu+JEz3xCh1mrXeYoN5o+trLL3IXJacSsLYXDrYTipZZbJFRPAucgbnjYBC+/ZzJOfkwCs+Gkw7EoZR7ZQgJ8ma+9586n4tT4cI8DEhBSZsWMjrCt8dxKg=="

private let echoTool = Tool(
    name: "echo", description: "Echoes the message back",
    parameters: cJSON(#"{"type":"object","properties":{"message":{"description":"Message to echo back","type":"string"}},"required":["message"]}"#)
)

private func buildPrefilledMessages() -> [Message] {
    cMessages(#"""
    [{"role":"user","content":"Use the echo tool to echo 'hello'"},
     {"role":"assistant","content":[{"type":"toolCall","id":"\#(failingToolCallId)","name":"echo","arguments":{"message":"hello"}}],"api":"openai-responses","provider":"github-copilot","model":"gpt-5.2-codex","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse"},
     {"role":"toolResult","toolCallId":"\#(failingToolCallId)","toolName":"echo","content":[{"type":"text","text":"hello"}],"isError":false},
     {"role":"user","content":"Say hi"}]
    """#)
}

@Suite("Tool Call ID Normalization - Prefilled Context")
struct ToolCallIdNormalizationTests {
    @Test("openrouter should handle prefilled context with long pipe-separated IDs")
    func openRouterPrefilled() async throws {
        let model = cBuiltin("openrouter", "openai/gpt-5.5")
        #expect(model.api == "openai-completions")
        let run = try await cRunSimple(model, Context(systemPrompt: "You are a helpful assistant.", messages: buildPrefilledMessages(), tools: [echoTool]))

        #expect(run.result.stopReason != .error, "OpenRouter error: \(run.result.errorMessage ?? "")")
        let messages = try #require(run.payload["messages"]?.arrayValue)
        let assistant = try #require(messages.first { $0["role"] == "assistant" })
        let sentId = try #require(assistant["tool_calls"]?[0]?["id"]?.stringValue)
        #expect(sentId.count <= 40)
        #expect(sentId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        #expect(sentId.hasPrefix("call_pAYbIr76hXIjncD9UE4eGfnS"))
        let tool = try #require(messages.first { $0["role"] == "tool" })
        #expect(tool["tool_call_id"]?.stringValue == sentId)
    }
}
