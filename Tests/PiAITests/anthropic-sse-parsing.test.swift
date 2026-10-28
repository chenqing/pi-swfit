import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-sse-parsing.test.ts
// Swift: upstream's fake `client` (whose `beta.messages.create().asResponse()` returns a canned Response) is a real
// SDK client over a fake `FetchFunction`; request params are read from the captured JSON body and headers.

// Mirrors the generated catalog entry for anthropic/claude-haiku-4-5 (only the fields these tests depend on).
private let claudeHaiku45 = bModel(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", baseUrl: "https://api.anthropic.com")
// Mirrors the generated catalog entry for anthropic/claude-opus-5.
private let claudeOpus5 = bModel(id: "claude-opus-5", name: "Claude Opus 5", baseUrl: "https://api.anthropic.com")
// Mirrors the generated catalog entry for anthropic/claude-fable-5.
private let claudeFable5 = bModel(id: "claude-fable-5", name: "Claude Fable 5", baseUrl: "https://api.anthropic.com")
// Mirrors the generated catalog entry for anthropic/claude-fable-5-1: getAnthropicMessagesCompat marks it
// supportsMidConvoEffort (verified provider + /^claude-(?:fable|mythos)-5(?:[.-]1)/).
private let claudeFable51 = bModel(
    id: "claude-fable-5-1",
    name: "Claude Fable 5.1",
    baseUrl: "https://api.anthropic.com",
    compat: ["supportsMidConvoEffort": true]
)
// Mirrors the generated catalog entry for openrouter/anthropic/claude-haiku-4.5.
private let openRouterHaiku45 = bModel(
    id: "anthropic/claude-haiku-4.5",
    name: "Anthropic: Claude Haiku 4.5",
    provider: "openrouter",
    baseUrl: "https://openrouter.ai/api"
)

/// `createFakeAnthropicClient(response)`: a client whose every request answers with `body`.
private func fakeClient(_ body: String, requests: BRequests? = nil) throws -> Anthropic {
    try PiAnthropic(Anthropic.ClientOptions(
        apiKey: .some("fake-key"),
        authToken: .some(nil),
        baseURL: "http://127.0.0.1:9",
        fetch: bFetch(body, requests: requests)
    ))
}

private func helloContext(_ text: String = "Hello", tools: [Tool]? = nil) -> TranscriptContext {
    normalizeContext(bUserContext(text, tools: tools))
}

private func streamWith(_ model: Model, _ context: TranscriptContext, _ options: AnthropicOptions) async -> AssistantMessage {
    await streamAnthropicMessages(model, context, options).result()
}

private enum ResponseContentBlock {
    case thinking(thinking: String, signature: String)
    case text(String)

    var json: JsonValue {
        switch self {
        case .thinking(let thinking, let signature):
            return ["type": "thinking", "thinking": .string(thinking), "signature": .string(signature)]
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        }
    }
}

private func responseModelSse(_ model: String, _ contentBlock: ResponseContentBlock) -> String {
    bSseBody(json: [
        ("message_start", [
            "type": "message_start",
            "message": ["id": "msg_response_model", "model": .string(model), "usage": ["input_tokens": 100, "output_tokens": 0]],
        ]),
        ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": contentBlock.json]),
        ("content_block_stop", ["type": "content_block_stop", "index": 0]),
        ("message_delta", [
            "type": "message_delta",
            "delta": ["stop_reason": "end_turn"],
            "usage": ["input_tokens": 100, "output_tokens": 20],
        ]),
        ("message_stop", ["type": "message_stop"]),
    ])
}

private let zeroUsage12: JsonValue = ["input_tokens": 12, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
private let usage12x5: JsonValue = ["input_tokens": 12, "output_tokens": 5, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]

@Suite("Anthropic raw SSE parsing")
struct AnthropicSseParsingTests {
    @Test("forwards parsed provider stream events in order")
    func forwardsProviderEvents() async throws {
        let model = claudeHaiku45
        let seen = Locked<[(type: String, model: Model)]>([])
        var options = AnthropicOptions(client: try fakeClient(bSseBody(json: bMinimalAnthropicEvents)))
        options.onProviderStreamEvent = { event, eventModel in
            await Task.yield()
            seen.withLock { $0.append((event["type"]?.stringValue ?? "", eventModel)) }
        }
        let result = await streamWith(model, helloContext(), options)

        #expect(result.stopReason == .stop)
        let events = seen.withLock { $0 }
        #expect(events.map(\.type) == [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
        ])
        #expect(events.map(\.model.json) == Array(repeating: model.json, count: 6))
    }

    @Test("keeps signed thinking replayable when a proxy relabels the model")
    func relabeledModelReplay() async throws {
        // Regression test for earendil-works/pi#9188.
        let model = claudeOpus5
        let responseModel = "kimi-for-coding"
        let initialContext = helloContext()
        let first = await streamWith(model, initialContext, AnthropicOptions(client: try fakeClient(
            responseModelSse(responseModel, .thinking(thinking: "reasoning", signature: "signature"))
        )))

        #expect(first.model == model.id)
        #expect(first.responseModel == responseModel)

        let transformed = transformMessages(initialContext.messages + [.assistant(first)], model)
        let replayedAssistant = transformed.compactMap { message -> AssistantMessage? in
            if case .assistant(let assistant) = message { return assistant }
            return nil
        }.first
        #expect(replayedAssistant?.content == [
            .thinking(ThinkingContent(thinking: "reasoning", thinkingSignature: "signature")),
        ])
    }

    @Test("uses a returned fallback model for cost attribution")
    func fallbackModelCost() async throws {
        let fallbackModel = "fallback-model"
        var model = claudeOpus5
        model.compat = [
            "allowedFallbackModels": [
                [
                    "provider": "anthropic",
                    "model": .string(fallbackModel),
                    "cost": ["input": 3, "output": 5, "cacheRead": 0, "cacheWrite": 0],
                ],
            ],
        ]
        let result = await streamWith(model, helloContext(), AnthropicOptions(client: try fakeClient(
            responseModelSse(fallbackModel, .text("done"))
        )))

        #expect(result.model == model.id)
        #expect(result.responseModel == fallbackModel)
        #expect(abs(result.usage.cost.input - 0.0003) < 1e-10)
        #expect(abs(result.usage.cost.output - 0.0001) < 1e-10)
    }

    @Test("fails safely when Anthropic falls back after output begins")
    func midOutputFallback() async throws {
        let body = bSseBody(json: [
            ("message_start", [
                "type": "message_start",
                "message": ["id": "msg_fallback", "model": "claude-opus-5", "usage": ["input_tokens": 1, "output_tokens": 0]],
            ]),
            ("content_block_start", [
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "text", "text": "partial"],
            ]),
            ("content_block_stop", ["type": "content_block_stop", "index": 0]),
            ("content_block_start", [
                "type": "content_block_start",
                "index": 1,
                "content_block": [
                    "type": "fallback",
                    "from": ["model": "claude-opus-5"],
                    "to": ["model": "claude-opus-4-8"],
                ],
            ]),
        ])
        let result = await streamWith(claudeOpus5, helloContext(), AnthropicOptions(client: try fakeClient(body)))

        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("unsupported mid-output model fallback") == true)
    }

    @Test("forces streaming after an onPayload replacement")
    func forcesStreaming() async throws {
        let requests = BRequests()
        var options = AnthropicOptions(client: try fakeClient(bSseBody(json: bMinimalAnthropicEvents), requests: requests))
        options.onPayload = { payload, _ in
            var object = payload.objectValue ?? JsonObject()
            object["stream"] = false
            return .object(object)
        }
        _ = await streamWith(claudeFable51, helloContext(), options)

        #expect(requests.lastBody?["stream"] == true)
    }

    @Test("omits the interleaved-thinking beta when thinking is disabled")
    func omitsInterleavedBetaWhenDisabled() async throws {
        let requests = BRequests()
        let options = AnthropicOptions(
            thinkingEnabled: false,
            client: try fakeClient(bSseBody(json: bMinimalAnthropicEvents), requests: requests)
        )
        _ = await streamWith(openRouterHaiku45, helloContext(), options)

        let betas = requests.last?.headers.get("anthropic-beta") ?? ""
        #expect(!betas.contains("interleaved-thinking-2025-05-14"))
    }

    @Test("passes managed beta features to injected clients")
    func managedBetasOnInjectedClient() async throws {
        let requests = BRequests()
        let result = await streamWith(claudeFable51, helloContext(), AnthropicOptions(
            client: try fakeClient(bSseBody(json: bMinimalAnthropicEvents), requests: requests)
        ))

        #expect(result.stopReason == .stop)
        let betas = (requests.last?.headers.get("anthropic-beta") ?? "").split(separator: ",").map { String($0) }
        #expect(betas.contains("mid-conversation-output-config-2026-07-01"))
        #expect(betas.contains("thinking-binding-controls-2026-08-01"))
    }

    @Test("uses the serving model input transformations from the final stream event")
    func inputTransformations() async throws {
        var events = bMinimalAnthropicEvents
        events[0].data = [
            "type": "message_start",
            "message": [
                "id": "msg_transformations",
                "model": "claude-fable-5-1",
                "usage": ["input_tokens": 12, "output_tokens": 0],
                "input_transformations": [
                    ["type": "thinking_dropped", "path": "messages.1.content.0", "reason": "prefix_binding_mismatch"],
                ],
            ],
        ]
        var delta = events[4].data.objectValue ?? JsonObject()
        delta["input_transformations"] = [
            ["type": "thinking_dropped", "path": "messages.3.content.0", "reason": "model_binding_mismatch"],
        ]
        events[4].data = .object(delta)

        let result = await streamWith(claudeFable51, helloContext(), AnthropicOptions(client: try fakeClient(bSseBody(json: events))))

        let diagnostics = try #require(result.diagnostics)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.type == "anthropic_input_transformations")
        #expect(diagnostics.first?.error == nil)
        #expect(diagnostics.first?.details == [
            "transformations": [
                [
                    "type": "thinking_dropped",
                    "path": "messages.3.content.0",
                    "reason": "model_binding_mismatch",
                ],
            ],
        ])
    }

    @Test("repairs malformed SSE JSON and malformed streamed tool JSON")
    func repairsMalformedToolJson() async throws {
        let tools = [Tool(
            name: "edit",
            description: "Edit a file.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"], "text": ["type": "string"]],
                "required": ["path", "text"],
            ]
        )]
        // String.raw with a literal tab between col1 and col2.
        let malformedToolJsonDelta =
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"A\H\",\"text\":\"col1"#
            + "\t"
            + #"col2\"}"}}"#

        let body = bSseBody([
            ("message_start", JsonValue.object([
                "type": "message_start",
                "message": ["id": "msg_test", "usage": zeroUsage12],
            ]).serialized()),
            ("content_block_start", JsonValue.object([
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "tool_use", "id": "toolu_test", "name": "edit", "input": [:]],
            ]).serialized()),
            ("content_block_delta", malformedToolJsonDelta),
            ("content_block_stop", JsonValue.object(["type": "content_block_stop", "index": 0]).serialized()),
            ("message_delta", JsonValue.object([
                "type": "message_delta",
                "delta": ["stop_reason": "tool_use"],
                "usage": usage12x5,
            ]).serialized()),
            ("message_stop", JsonValue.object(["type": "message_stop"]).serialized()),
        ])

        let result = await streamWith(
            claudeHaiku45,
            helloContext("Use the edit tool.", tools: tools),
            AnthropicOptions(client: try fakeClient(body))
        )

        #expect(result.stopReason == .toolUse)
        #expect(result.errorMessage == nil)

        let toolCall = result.content.compactMap(\.toolCallContent).first
        #expect(toolCall != nil)
        #expect(toolCall?.arguments == [
            "path": "A\\H",
            "text": "col1\tcol2",
        ])
    }

    @Test("preserves content from content_block_start events")
    func preservesInitialContent() async throws {
        let body = bSseBody(json: [
            ("message_start", [
                "type": "message_start",
                "message": ["id": "msg_initial_content", "usage": zeroUsage12],
            ]),
            ("content_block_start", [
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "text", "text": "Initial text"],
            ]),
            ("content_block_delta", [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": " plus delta"],
            ]),
            ("content_block_stop", ["type": "content_block_stop", "index": 0]),
            ("content_block_start", [
                "type": "content_block_start",
                "index": 1,
                "content_block": ["type": "thinking", "thinking": "Initial thinking", "signature": "initial signature"],
            ]),
            ("content_block_delta", [
                "type": "content_block_delta",
                "index": 1,
                "delta": ["type": "thinking_delta", "thinking": " plus delta"],
            ]),
            ("content_block_delta", [
                "type": "content_block_delta",
                "index": 1,
                "delta": ["type": "signature_delta", "signature": " plus delta"],
            ]),
            ("content_block_stop", ["type": "content_block_stop", "index": 1]),
            ("message_delta", [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": usage12x5,
            ]),
            ("message_stop", ["type": "message_stop"]),
        ])

        let result = await streamWith(claudeHaiku45, helloContext("Say hello."), AnthropicOptions(client: try fakeClient(body)))

        #expect(result.content == [
            .text(TextContent(text: "Initial text plus delta")),
            .thinking(ThinkingContent(
                thinking: "Initial thinking plus delta",
                thinkingSignature: "initial signature plus delta"
            )),
        ])
    }

    @Test("preserves refusal stop details from message_delta")
    func refusalStopDetails() async throws {
        let explanation =
            "This request triggered restrictions on violative cyber content and was blocked under Anthropic's Usage Policy. To learn more, provide feedback, or request an exemption based on how you use Claude, visit our help center: https://support.claude.com/en/articles/14604842-real-time-cyber-safeguards-on-claude."
        let usage: JsonValue = ["input_tokens": 412, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
        let body = bSseBody(json: [
            ("message_start", [
                "type": "message_start",
                "message": ["id": "msg_01XFUDYJgAACzvnptvVoYEL", "usage": usage],
            ]),
            ("message_delta", [
                "type": "message_delta",
                "delta": [
                    "stop_reason": "refusal",
                    "stop_details": ["type": "refusal", "category": "cyber", "explanation": .string(explanation)],
                ],
                "usage": usage,
            ]),
            ("message_stop", ["type": "message_stop"]),
        ])

        let result = await streamWith(claudeFable5, helloContext("blocked request"), AnthropicOptions(client: try fakeClient(body)))

        #expect(result.stopReason == .error)
        #expect(result.rawStopReason == "refusal")
        #expect(result.errorMessage == explanation)
    }

    @Test("preserves sensitive stop reasons with a descriptive error message")
    func sensitiveStopReason() async throws {
        let body = bSseBody(json: [
            ("message_start", [
                "type": "message_start",
                "message": ["id": "msg_sensitive", "usage": zeroUsage12],
            ]),
            ("message_delta", [
                "type": "message_delta",
                "delta": ["stop_reason": "sensitive"],
                "usage": zeroUsage12,
            ]),
            ("message_stop", ["type": "message_stop"]),
        ])

        let result = await streamWith(claudeHaiku45, helloContext("blocked request"), AnthropicOptions(client: try fakeClient(body)))

        #expect(result.stopReason == .error)
        #expect(result.rawStopReason == "sensitive")
        #expect(result.errorMessage == "Provider stopped with: sensitive")
    }

    @Test("treats message_delta without usage as a no-op for usage accumulation")
    func messageDeltaWithoutUsage() async throws {
        let events = bMinimalAnthropicEvents.map { event -> (event: String, data: JsonValue) in
            event.event == "message_delta"
                ? ("message_delta", ["type": "message_delta", "delta": ["stop_reason": "end_turn"]])
                : event
        }

        let result = await streamWith(claudeHaiku45, helloContext("Say hello."), AnthropicOptions(client: try fakeClient(bSseBody(json: events))))

        #expect(result.stopReason == .stop)
        #expect(result.errorMessage == nil)
        #expect(result.content == [.text(TextContent(text: "Hello"))])
        #expect(result.usage.input == 12)
        #expect(result.usage.totalTokens == 12)
    }

    @Test("ignores unknown SSE events after message_stop")
    func ignoresUnknownEventsAfterStop() async throws {
        let body = bSseBody(
            bMinimalAnthropicEvents.map { ($0.event, $0.data.serialized()) } + [
                ("done", "[DONE]"),
                ("proxy.stats", "not json"),
            ]
        )

        let result = await streamWith(claudeHaiku45, helloContext("Say hello."), AnthropicOptions(client: try fakeClient(body)))

        #expect(result.stopReason == .stop)
        #expect(result.errorMessage == nil)
        #expect(result.content == [.text(TextContent(text: "Hello"))])
    }
}
