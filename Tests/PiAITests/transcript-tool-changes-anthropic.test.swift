import Foundation
import Testing
@testable import PiAI

// Port of the anthropic-messages cases of packages/ai/test/transcript-tool-changes.test.ts
// (the transcript.ts case lives in transcript-tool-changes.test.swift).

/// `Type.Object({})`
private let emptyObjectSchema: JsonValue = ["type": "object", "properties": [:]]

private func tool(_ name: String) -> Tool {
    Tool(name: name, description: "\(name) tool", parameters: emptyObjectSchema)
}

private let baseTool = tool("base_tool")
private let lateTool = tool("late_tool")

private func anthropicModel(_ id: String, _ name: String, compat: JsonObject? = nil) -> Model {
    Model(
        id: id,
        name: name,
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: "http://127.0.0.1:9",
        reasoning: true,
        input: ["text"],
        cost: ModelCost(),
        contextWindow: 100_000,
        maxTokens: 1000,
        compat: compat
    )
}

private let anthropicNativeModel = anthropicModel(
    "claude-opus-5",
    "Claude Opus 5",
    compat: ["supportsMidConvoSystemMessages": true, "supportsMidConvoToolChanges": true]
)

private let contextMessages: [Message] = [
    .system(SystemMessage(
        content: "base prompt",
        sections: [("rules", "<rules>\nold rules\n</rules>"), ("docs", "<docs>\nread docs\n</docs>")],
        toolsAdded: [baseTool],
        timestamp: 0
    )),
    .user(UserMessage(content: "before", timestamp: 1)),
    .system(SystemMessage(
        content: "updated guidance",
        sections: [("rules", "<rules>\nnew rules\n</rules>"), ("docs", nil)],
        toolsAdded: [lateTool],
        toolsRemoved: [ToolReference(name: "base_tool")],
        timestamp: 2
    )),
]

private func capturePayload(_ model: Model, _ messages: [Message]) async throws -> JsonObject {
    var options = SimpleStreamOptions()
    options.apiKey = "test-key"
    return try #require(await bCapturePayload(model, Context(messages: messages), options), "Expected payload capture")
}

private func strings(_ value: JsonValue?) -> [String] { (value?.arrayValue ?? []).compactMap(\.stringValue) }

/// vitest `toMatchObject`: objects match recursively by subset, arrays element-wise with equal length.
private func matchesObject(_ actual: JsonValue?, _ expected: JsonValue) -> Bool {
    switch expected {
    case .object(let expectedObject):
        guard case .object(let actualObject)? = actual else { return false }
        return expectedObject.allSatisfy { matchesObject(actualObject[$0.key], $0.value) }
    case .array(let expectedArray):
        guard case .array(let actualArray)? = actual, actualArray.count == expectedArray.count else { return false }
        return zip(actualArray, expectedArray).allSatisfy { matchesObject($0, $1) }
    default:
        return actual == expected
    }
}

@Suite("transcript system messages (anthropic-messages)")
struct TranscriptToolChangesAnthropicTests {
    @Test("sends Anthropic updates and tool changes in native system messages")
    func sendsNativeSystemMessages() async throws {
        let payload = try await capturePayload(anthropicNativeModel, contextMessages)

        #expect(strings(payload["betas"]).contains("inline-tools-2026-09-15"))
        #expect(!strings(payload["betas"]).contains("mid-conversation-tool-changes-2026-07-01"))
        #expect((payload["system"]?.arrayValue ?? []).map { $0["text"] } == [
            "base prompt\n\n<rules>\nold rules\n</rules>\n\n<docs>\nread docs\n</docs>",
        ])
        // The top-level list holds only the initial tools (with the cache breakpoint) and the
        // deferred placeholder; later tools never appear there.
        #expect(matchesObject(payload["tools"], [
            ["name": "base_tool", "cache_control": ["type": "ephemeral"]],
            ["name": "__pi_deferred_placeholder__", "defer_loading": true],
        ]))
        #expect(payload["tools"]?.arrayValue?.count == 2)
        #expect(payload["tools"]?[0]?["defer_loading"] == nil)
        #expect(payload["tools"]?[1]?["cache_control"] == nil)
        let update = payload["messages"]?.arrayValue?.last
        #expect(matchesObject(update, [
            "role": "system",
            "content": [
                ["type": "text"],
                ["type": "tool_removal", "tool": ["type": "tool_reference", "name": "base_tool"]],
                [
                    "type": "tool_addition",
                    "tool": ["type": "tool_definition", "definition": ["name": "late_tool", "description": "late_tool tool"]],
                    "cache_control": ["type": "ephemeral"],
                ],
            ],
        ]))
        // Cache control goes on the block, never on the inline definition; nothing is deferred.
        let definition = update?["content"]?[2]?["tool"]?["definition"]
        #expect(definition?["cache_control"] == nil)
        #expect(definition?["defer_loading"] == nil)
        let text = update?["content"]?[0]?["text"]?.stringValue ?? ""
        #expect(text.contains("updated guidance"))
        #expect(text.contains("<rules>\nnew rules\n</rules>"))
        #expect(text.contains("Removed system prompt section \"docs\""))

        // The placeholder is declared before any change so its scaffolding is cached from request one.
        let initial = try await capturePayload(anthropicNativeModel, Array(contextMessages.prefix(2)))
        #expect((initial["tools"]?.arrayValue ?? []).map { $0["name"] } == ["base_tool", "__pi_deferred_placeholder__"])
    }

    @Test("redefines an Anthropic tool by value under the same name")
    func redefinesToolByValue() async throws {
        var redefinedTool = baseTool
        redefinedTool.description = "changed"
        let payload = try await capturePayload(anthropicNativeModel, [
            .system(SystemMessage(content: "base prompt", toolsAdded: [baseTool], timestamp: 0)),
            .user(UserMessage(content: "before", timestamp: 1)),
            .system(SystemMessage(
                content: "",
                toolsAdded: [redefinedTool],
                toolsRemoved: [ToolReference(name: "base_tool")],
                timestamp: 2
            )),
        ])

        #expect(strings(payload["betas"]).contains("inline-tools-2026-09-15"))
        // The top-level declaration keeps the original definition, so the cached prefix survives.
        #expect(matchesObject(payload["tools"], [
            ["name": "base_tool", "description": "base_tool tool"],
            ["name": "__pi_deferred_placeholder__"],
        ]))
        // The new definition replaces the old one in place; no removal block is sent for it.
        let last = payload["messages"]?.arrayValue?.last
        #expect(matchesObject(last, [
            "role": "system",
            "content": [
                [
                    "type": "tool_addition",
                    "tool": ["type": "tool_definition", "definition": ["name": "base_tool", "description": "changed"]],
                ],
            ],
        ]))
        #expect(last?["content"]?.arrayValue?.count == 1)
    }

    @Test("sends the current Anthropic tool list without an initial tool")
    func sendsCurrentToolListWithoutInitialTool() async throws {
        // Anthropic rejects a tool list where every tool (here: the placeholder) is deferred.
        let payload = try await capturePayload(anthropicNativeModel, [
            .system(SystemMessage(content: "base prompt", timestamp: 0)),
            .user(UserMessage(content: "before", timestamp: 1)),
            .system(SystemMessage(content: "updated guidance", toolsAdded: [lateTool], timestamp: 2)),
        ])
        #expect(!strings(payload["betas"]).contains("inline-tools-2026-09-15"))
        #expect(matchesObject(payload["tools"], [["name": "late_tool", "cache_control": ["type": "ephemeral"]]]))
        #expect(payload["tools"]?[0]?["defer_loading"] == nil)
        #expect((payload["messages"]?.arrayValue?.last?["content"]?.arrayValue ?? []).map { $0["type"] } == ["text"])
    }

    // #11091
    @Test("holds an Anthropic update past an assistant message that converts to no blocks")
    func holdsUpdatePastDroppedAssistant() async throws {
        func reply(_ text: String, _ provider: String, _ api: String, _ model: String) -> Message {
            .assistant(AssistantMessage(content: [.text(TextContent(text: text))], api: api, provider: provider, model: model,
                                        stopReason: .stop, timestamp: 3))
        }
        let messages: [Message] = [
            .system(SystemMessage(content: "base prompt", timestamp: 0)),
            .user(UserMessage(content: "hi", timestamp: 1)),
            .system(SystemMessage(content: "updated guidance", timestamp: 2)),
            // Another model's empty reply: Anthropic rejects empty text blocks, so it is dropped.
            reply("", "openai-codex", "openai-codex-responses", "gpt-x"),
            .user(UserMessage(content: "again", timestamp: 4)),
        ]
        func roles(_ payload: JsonObject) -> [String] {
            (payload["messages"]?.arrayValue ?? []).compactMap { $0["role"]?.stringValue }
        }

        // No later assistant: the update goes at the end.
        let atEnd = try await capturePayload(anthropicNativeModel, messages)
        #expect(roles(atEnd) == ["user", "user", "system"])

        // A later assistant that is sent: the update goes directly before it.
        let beforeAssistant = try await capturePayload(anthropicNativeModel, messages + [
            reply("answer", anthropicNativeModel.provider, anthropicNativeModel.api, anthropicNativeModel.id),
            .user(UserMessage(content: "third", timestamp: 5)),
        ])
        #expect(roles(beforeAssistant) == ["user", "user", "system", "assistant", "user"])
    }

    @Test("folds Anthropic updates into the system prompt without native support")
    func foldsUpdatesWithoutNativeSupport() async throws {
        let model = anthropicModel("claude-sonnet-4-5", "Claude Sonnet 4.5")
        let payload = try await capturePayload(model, contextMessages)

        #expect(!strings(payload["betas"]).contains("inline-tools-2026-09-15"))
        #expect((payload["system"]?.arrayValue ?? []).map { $0["text"] } == [
            "base prompt\n\nupdated guidance\n\n<rules>\nnew rules\n</rules>",
        ])
        #expect((payload["tools"]?.arrayValue ?? []).map { $0["name"] } == ["late_tool"])
        #expect((payload["messages"]?.arrayValue ?? []).map { $0["role"] } == ["user"])
    }

    @Test("requires both Anthropic capabilities for native tool changes")
    func requiresBothCapabilities() async throws {
        let model = anthropicModel("claude-opus-5", "Claude Opus 5", compat: ["supportsMidConvoToolChanges": true])
        let payload = try await capturePayload(model, contextMessages)

        #expect(!strings(payload["betas"]).contains("inline-tools-2026-09-15"))
        #expect((payload["tools"]?.arrayValue ?? []).map { $0["name"] } == ["late_tool"])
        #expect((payload["messages"]?.arrayValue ?? []).map { $0["role"] } == ["user"])
    }
}
