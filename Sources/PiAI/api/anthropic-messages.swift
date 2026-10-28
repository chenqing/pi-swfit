import Foundation

// Port of packages/ai/src/api/anthropic-messages.ts
//
// Swift notes:
// - `stream` / `streamSimple` are exported as `streamAnthropicMessages` / `streamSimpleAnthropicMessages`.
// - `AnthropicOptions extends StreamOptions`: a struct wrapping `StreamOptions` (members forwarded with
//   `@dynamicMemberLookup`). Generic callers pass the Anthropic-only fields in `StreamOptions.extra`
//   (`ProviderStreamOptions = StreamOptions & Record<string, unknown>`); `AnthropicOptions(_:)` reads them.
// - Request params are `JsonObject`s built in upstream object-literal key order.
// - Provider-local scratch state of streamed blocks (`index`, `partialJson`) lives in side tables.

/**
 * Resolve cache retention preference.
 * Defaults to "short" and uses PI_CACHE_RETENTION for backward compatibility.
 */
private func resolveCacheRetention(_ cacheRetention: CacheRetention? = nil, _ env: ProviderEnv? = nil) -> CacheRetention {
    if let cacheRetention {
        return cacheRetention
    }
    if getProviderEnvValue("PI_CACHE_RETENTION", env) == "long" {
        return .long
    }
    return .short
}

/// `BetaCacheControlEphemeral`: `{ type: "ephemeral", ttl?: "1h" }`.
typealias CacheControlEphemeral = JsonObject

private func getCacheControl(
    _ model: Model,
    _ cacheRetention: CacheRetention? = nil,
    _ env: ProviderEnv? = nil
) -> (retention: CacheRetention, cacheControl: CacheControlEphemeral?) {
    let retention = resolveCacheRetention(cacheRetention, env)
    if retention == .none {
        return (retention, nil)
    }
    let ttl: String? = retention == .long && getAnthropicCompat(model).supportsLongCacheRetention ? "1h" : nil
    var cacheControl: CacheControlEphemeral = ["type": "ephemeral"]
    if let ttl { cacheControl["ttl"] = .string(ttl) }
    return (retention, cacheControl)
}

// Stealth mode: Mimic Claude Code's tool naming exactly
private let claudeCodeVersion = "2.1.280"

// Claude Code 2.x tool names (canonical casing)
// Source: https://cchistory.mariozechner.at/data/prompts-2.1.11.md
// To update: https://github.com/badlogic/cchistory
private let claudeCodeTools = [
    "Read",
    "Write",
    "Edit",
    "Bash",
    "Grep",
    "Glob",
    "AskUserQuestion",
    "EnterPlanMode",
    "ExitPlanMode",
    "KillShell",
    "NotebookEdit",
    "Skill",
    "Task",
    "TaskOutput",
    "TodoWrite",
    "WebFetch",
    "WebSearch",
]

private let ccToolLookup: [String: String] = Dictionary(claudeCodeTools.map { ($0.lowercased(), $0) }, uniquingKeysWith: { _, last in last })

// Convert tool name to CC canonical casing if it matches (case-insensitive)
private func toClaudeCodeName(_ name: String) -> String { ccToolLookup[name.lowercased()] ?? name }
private func fromClaudeCodeName(_ name: String, _ tools: [Tool]? = nil) -> String {
    if let tools, tools.count > 0 {
        let lowerName = name.lowercased()
        let matchedTool = tools.first { $0.name.lowercased() == lowerName }
        if let matchedTool { return matchedTool.name }
    }
    return name
}

private func convertImageBlock(_ image: ImageContent) -> JsonObject {
    [
        "type": "image",
        "source": [
            "type": "base64",
            "media_type": .string(image.mimeType),
            "data": .string(image.data),
        ],
    ]
}

/**
 * Convert content blocks to Anthropic API format
 */
private func convertContentBlocks(_ content: [UserContent]) -> JsonValue {
    // If only text blocks, return as concatenated string for simplicity
    let hasImages = content.contains { $0.type == "image" }
    if !hasImages {
        return .string(sanitizeSurrogates(content.map { $0.textContent?.text ?? "undefined" }.joined(separator: "\n")))
    }

    // If we have images, convert to content block array
    var blocks: [JsonObject] = content.map { block in
        if case .text(let text) = block {
            return [
                "type": "text",
                "text": .string(sanitizeSurrogates(text.text)),
            ]
        }
        return convertImageBlock(block.imageContent!)
    }

    // If only images (no text), add placeholder text block
    let hasText = blocks.contains { $0["type"] == "text" }
    if !hasText {
        blocks.insert([
            "type": "text",
            "text": "(see attached image)",
        ], at: 0)
    }

    return .array(blocks.map(JsonValue.object))
}

/// `"low" | "medium" | "high" | "xhigh" | "max"`. A struct so values mapped through `thinkingLevelMap`
/// pass through unchanged, like upstream's cast.
public struct AnthropicEffort: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static let low: AnthropicEffort = "low"
    public static let medium: AnthropicEffort = "medium"
    public static let high: AnthropicEffort = "high"
    public static let xhigh: AnthropicEffort = "xhigh"
    public static let max: AnthropicEffort = "max"
}

/// `"summarized" | "omitted"`.
public struct AnthropicThinkingDisplay: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static let summarized: AnthropicThinkingDisplay = "summarized"
    public static let omitted: AnthropicThinkingDisplay = "omitted"
}

/// `"auto" | "any" | "none" | { type: "tool"; name: string }`.
public enum AnthropicToolChoice: Sendable, Hashable {
    /// One of Anthropic's built-in choices (`"auto"`, `"any"`, `"none"`).
    case type(String)
    /// `{ type: "tool", name }` forces a specific tool.
    case tool(name: String)

    public static let auto = AnthropicToolChoice.type("auto")
    public static let any = AnthropicToolChoice.type("any")
    public static let none = AnthropicToolChoice.type("none")

    /// Reads the upstream JSON shape (a string or `{ type: "tool", name }`).
    public init?(json: JsonValue?) {
        switch json {
        case .string(let value)?:
            self = .type(value)
        case .object(let object)? where object["type"] == "tool":
            self = .tool(name: object["name"]?.stringValue ?? "")
        default:
            return nil
        }
    }
}

private let FINE_GRAINED_TOOL_STREAMING_BETA = "fine-grained-tool-streaming-2025-05-14"
private let INTERLEAVED_THINKING_BETA = "interleaved-thinking-2025-05-14"
private let SERVER_SIDE_FALLBACK_BETA = "server-side-fallback-2026-07-01"
private let MID_CONVERSATION_OUTPUT_CONFIG_BETA = "mid-conversation-output-config-2026-07-01"
private let THINKING_BINDING_CONTROLS_BETA = "thinking-binding-controls-2026-08-01"
private let INLINE_TOOLS_BETA = "inline-tools-2026-09-15"

/**
 * Stable deferred tool declared whenever native tool changes are in use. Anthropic adds
 * hidden prompt scaffolding for mid-conversation tool changes; declaring this placeholder
 * from the first request keeps that scaffolding in the cached prefix, so the first tool
 * change does not invalidate the cache (measured: full miss without it). It is never
 * activated and the model cannot see it.
 */
private let DEFERRED_TOOL_PLACEHOLDER: JsonObject = [
    "name": "__pi_deferred_placeholder__",
    "description": "Reserved placeholder. Never available. Never call this.",
    "input_schema": ["type": "object", "properties": [:], "required": []],
    "defer_loading": true,
]

private func shouldUseServerSideFallbackBeta(_ model: Model) -> Bool {
    (AnthropicMessagesCompat(json: model.compat).allowedFallbackModels?.count ?? 0) > 0
}

private struct AnthropicCompat {
    var supportsEagerToolInputStreaming: Bool
    var supportsLongCacheRetention: Bool
    var sendSessionAffinityHeaders: Bool
    var sessionAffinityFormat: AnthropicSessionAffinityFormat?
    var supportsCacheControlOnTools: Bool
    var supportsTemperature: Bool
    var allowEmptySignature: Bool
    var supportsStrictTools: Bool
    var supportsMidConvoSystemMessages: Bool
    var supportsMidConvoToolChanges: Bool
}

private func getAnthropicCompat(_ model: Model) -> AnthropicCompat {
    let isOpenRouter = model.provider == "openrouter" || model.baseUrl.contains("openrouter.ai")
    let compat = AnthropicMessagesCompat(json: model.compat)
    return AnthropicCompat(
        supportsEagerToolInputStreaming: compat.supportsEagerToolInputStreaming ?? true,
        supportsLongCacheRetention: compat.supportsLongCacheRetention ?? true,
        sendSessionAffinityHeaders: compat.sendSessionAffinityHeaders ?? isOpenRouter,
        sessionAffinityFormat: compat.sessionAffinityFormat ?? (isOpenRouter ? .openrouter : nil),
        supportsCacheControlOnTools: compat.supportsCacheControlOnTools ?? true,
        supportsTemperature: compat.supportsTemperature ?? true,
        allowEmptySignature: compat.allowEmptySignature ?? false,
        supportsStrictTools: compat.supportsStrictTools ?? false,
        supportsMidConvoSystemMessages: compat.supportsMidConvoSystemMessages ?? false,
        supportsMidConvoToolChanges: compat.supportsMidConvoToolChanges ?? false
    )
}

/// `AnthropicOptions extends StreamOptions`. Every `StreamOptions` member is reachable directly
/// (`options.signal`, `options.apiKey`, ...).
@dynamicMemberLookup
public struct AnthropicOptions: Sendable {
    /// The inherited `StreamOptions` fields.
    public var base: StreamOptions
    /**
     * Enable extended thinking.
     * For adaptive thinking models: the model decides when/how much to think.
     * For older models: uses budget-based thinking with thinkingBudgetTokens.
     * Default: undefined (thinking is omitted unless `streamSimple()` maps
     * a simple reasoning level to this option, or callers set it explicitly).
     */
    public var thinkingEnabled: Bool?
    /**
     * Token budget for extended thinking (older models only).
     * Ignored for adaptive thinking models.
     * Default: 1024 when `thinkingEnabled` is true and no budget is provided.
     */
    public var thinkingBudgetTokens: Int?
    /**
     * Effort level for adaptive thinking models.
     * Controls how much thinking Claude allocates:
     * - "max": Always thinks with no constraints (Opus 4.6 only)
     * - "xhigh": Highest reasoning level (Opus 4.7+, Fable 5)
     * - "high": Always thinks, deep reasoning
     * - "medium": Moderate thinking, may skip for simple queries
     * - "low": Minimal thinking, skips for simple tasks
     * Ignored for older models.
     * Default: omitted unless `streamSimple()` maps a simple reasoning
     * level to this option.
     */
    public var effort: AnthropicEffort?
    /**
     * Controls how thinking content is returned in API responses.
     * - "summarized": Thinking blocks contain summarized thinking text.
     * - "omitted": Thinking blocks return an empty thinking field; the encrypted
     *   signature still travels back for multi-turn continuity. Use for faster
     *   time-to-first-text-token when your UI does not surface thinking.
     *
     * Note: Anthropic's API default for Claude Opus 4.7 and Claude Mythos Preview
     * is "omitted". We default to "summarized" here to keep behavior consistent
     * with older Claude 4 models. Set this explicitly to "omitted" to opt in.
     * Default: "summarized" when thinking is enabled.
     */
    public var thinkingDisplay: AnthropicThinkingDisplay?
    /**
     * Whether to request the interleaved thinking beta header for non-adaptive
     * thinking models. Adaptive thinking models have interleaved thinking built in,
     * so the header is skipped for them regardless of this setting.
     * Default: true.
     */
    public var interleavedThinking: Bool?
    /**
     * Anthropic tool choice behavior. String values map to Anthropic's built-in
     * choices; `{ type: "tool", name }` forces a specific tool.
     * Default: omitted (Anthropic default behavior, currently equivalent to auto).
     */
    public var toolChoice: AnthropicToolChoice?
    /**
     * Pre-built Anthropic client instance. When provided, skips internal client
     * construction entirely. Use this to inject alternative SDK clients such as
     * `AnthropicVertex` that shares the same messaging API.
     */
    public var client: Anthropic?

    public init(
        _ base: StreamOptions = StreamOptions(),
        thinkingEnabled: Bool? = nil,
        thinkingBudgetTokens: Int? = nil,
        effort: AnthropicEffort? = nil,
        thinkingDisplay: AnthropicThinkingDisplay? = nil,
        interleavedThinking: Bool? = nil,
        toolChoice: AnthropicToolChoice? = nil,
        client: Anthropic? = nil
    ) {
        self.base = base
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.effort = effort
        self.thinkingDisplay = thinkingDisplay
        self.interleavedThinking = interleavedThinking
        self.toolChoice = toolChoice
        self.client = client
    }

    /// Reads the Anthropic fields from a generic options object (`StreamOptions.extra`, plus the
    /// simple `toolChoice`), as upstream's structural `AnthropicOptions` would see them.
    public init(streamOptions options: StreamOptions) {
        let extra = options.extra
        self.init(
            options,
            thinkingEnabled: extra["thinkingEnabled"]?.boolValue,
            thinkingBudgetTokens: extra["thinkingBudgetTokens"]?.doubleValue.map { Int($0) },
            effort: extra["effort"]?.stringValue.map(AnthropicEffort.init(rawValue:)),
            thinkingDisplay: extra["thinkingDisplay"]?.stringValue.map(AnthropicThinkingDisplay.init(rawValue:)),
            interleavedThinking: extra["interleavedThinking"]?.boolValue,
            toolChoice: AnthropicToolChoice(json: extra["toolChoice"]) ?? options.toolChoice.map(AnthropicToolChoice.type)
        )
    }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<StreamOptions, T>) -> T {
        get { base[keyPath: keyPath] }
        set { base[keyPath: keyPath] = newValue }
    }
}

private func mergeHeaders(_ headerSources: [ProviderHeaders?]) -> ProviderHeaders {
    // `Object.assign`: an existing key keeps its position and takes the new value.
    var merged: ProviderHeaders = []
    for headers in headerSources {
        if let headers {
            for (key, value) in headers {
                if let index = merged.firstIndex(where: { $0.0 == key }) {
                    merged[index].1 = value
                } else {
                    merged.append((key, value))
                }
            }
        }
    }
    return merged
}

private func mergeClientHeaders(_ identityHeaders: ProviderHeaders, _ headerSources: ProviderHeaders?...) -> ProviderHeaders {
    mergeHeaders([identityHeaders] + headerSources)
}

private func hasHeader(_ headers: ProviderHeaders?, _ name: String) -> Bool {
    guard let headers else { return false }
    let expected = name.lowercased()
    for (key, value) in headers {
        if key.lowercased() == expected, let value, jsTrim(value).count > 0 { return true }
    }
    return false
}

private func hasRequestAuth(_ apiKey: String?, _ headers: ProviderHeaders?) -> Bool {
    (apiKey?.isEmpty == false) ||
        hasHeader(headers, "authorization") ||
        hasHeader(headers, "x-api-key") ||
        hasHeader(headers, "cf-aig-authorization")
}

private func assertRequestAuth(_ provider: String, _ apiKey: String?, _ headers: ProviderHeaders?) throws {
    if !hasRequestAuth(apiKey, headers) { throw PiError("No API key for provider: \(provider)") }
}

/**
 * Anthropic SDK client that never runs the SDK's own credential chain
 * (ANTHROPIC_PROFILE config files, federation env vars). Without this, every
 * client built with `apiKey: null, authToken: null` for header-owned auth would
 * also resolve and exchange SDK credentials behind pi's auth resolver.
 */
final class PiAnthropic: Anthropic, @unchecked Sendable {
    override func _shouldResolveDefaultCredentials() -> Bool {
        false
    }
}

private typealias AnthropicFederationConfig = AnthropicConfig

/**
 * Workload identity federation config from the ANTHROPIC_* variables the
 * Anthropic SDK documents; the SDK performs the token exchange and refresh.
 * Only for the anthropic provider, since the exchange is an Anthropic API
 * endpoint, and only when no key or auth header was resolved.
 */
private func getAnthropicFederation(
    _ model: Model,
    _ apiKey: String?,
    _ headers: ProviderHeaders?,
    _ env: ProviderEnv?
) -> AnthropicFederationConfig? {
    if model.provider != "anthropic" || hasRequestAuth(apiKey, headers) { return nil }
    let federationRuleId = getProviderEnvValue(ANTHROPIC_FEDERATION_RULE_ID_ENV, env)
    let organizationId = getProviderEnvValue(ANTHROPIC_ORGANIZATION_ID_ENV, env)
    let identityTokenFile = getProviderEnvValue(ANTHROPIC_IDENTITY_TOKEN_FILE_ENV, env)
    guard let federationRuleId, !federationRuleId.isEmpty, let organizationId, !organizationId.isEmpty,
          let identityTokenFile, !identityTokenFile.isEmpty else { return nil }
    return AnthropicFederationConfig(
        authentication: AnthropicConfig.AuthenticationInfo(
            type: "oidc_federation",
            federation_rule_id: federationRuleId,
            service_account_id: getProviderEnvValue(ANTHROPIC_SERVICE_ACCOUNT_ID_ENV, env),
            identity_token: AnthropicConfig.IdentityToken(source: "file", path: identityTokenFile)
        ),
        organization_id: organizationId,
        workspace_id: getProviderEnvValue(ANTHROPIC_WORKSPACE_ID_ENV, env)
    )
}

/// `JSON.stringify(federation)` with upstream's object-literal key order (undefined fields omitted).
private func federationConfigJson(_ federation: AnthropicFederationConfig) -> JsonValue {
    var authentication: JsonObject = ["type": .string(federation.authentication.type)]
    if let value = federation.authentication.federation_rule_id { authentication["federation_rule_id"] = .string(value) }
    if let value = federation.authentication.service_account_id { authentication["service_account_id"] = .string(value) }
    if let token = federation.authentication.identity_token {
        authentication["identity_token"] = ["source": .string(token.source), "path": .string(token.path)]
    }
    var config: JsonObject = [:]
    if let value = federation.organization_id { config["organization_id"] = .string(value) }
    if let value = federation.workspace_id { config["workspace_id"] = .string(value) }
    config["authentication"] = .object(authentication)
    return .object(config)
}

/**
 * The SDK caches the federated access token per client, but pi creates a client
 * per request. Keep one client for the current federation config and fetch, and
 * clone it per request with `withOptions()`, which shares the token cache.
 *
 * Swift: closures have no `===`, so `fetch !== federationClient.fetch` compares the closure
 * representation (function pointer + context). The cache retains its closure, so its context
 * cannot be freed and reused by another closure.
 */
private let federationClient = Locked<(key: String, fetch: FetchFunction?, client: Anthropic)?>(nil)

private func sameFetch(_ a: FetchFunction?, _ b: FetchFunction?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?):
        return withUnsafeBytes(of: a) { ra in withUnsafeBytes(of: b) { rb in ra.elementsEqual(rb) } }
    default: return false
    }
}

// `ServerSentEvent` is shared with the SDK core (platform/sdk/StainlessCore.swift): same fields.

private struct SseDecoderState {
    var event: String?
    var data: [String]
    var raw: [String]
}

private let ANTHROPIC_MESSAGE_EVENTS: Set<String> = [
    "message_start",
    "message_delta",
    "message_stop",
    "content_block_start",
    "content_block_delta",
    "content_block_stop",
]

private func flushSseEvent(_ state: inout SseDecoderState) -> ServerSentEvent? {
    if (state.event ?? "").isEmpty && state.data.count == 0 {
        return nil
    }

    let event = ServerSentEvent(
        event: state.event,
        data: state.data.joined(separator: "\n"),
        raw: state.raw
    )
    state.event = nil
    state.data = []
    state.raw = []
    return event
}

private func decodeSseLine(_ line: String, _ state: inout SseDecoderState) -> ServerSentEvent? {
    if line == "" {
        return flushSseEvent(&state)
    }

    state.raw.append(line)
    if line.hasPrefix(":") {
        return nil
    }

    let delimiterIndex = line.firstIndex(of: ":")
    let fieldName = delimiterIndex.map { String(line[..<$0]) } ?? line
    var value = delimiterIndex.map { String(line[line.index(after: $0)...]) } ?? ""
    if value.hasPrefix(" ") {
        value.removeFirst()
    }

    if fieldName == "event" {
        state.event = value
    } else if fieldName == "data" {
        state.data.append(value)
    }

    return nil
}

private let CR: UInt8 = 0x0d
private let LF: UInt8 = 0x0a

/// Text buffer of decoded UTF-8 (`buffer` upstream), consumed line by line. Swift operates on the
/// UTF-8 bytes of the decoded text: CR and LF never occur inside a multi-byte sequence, so byte
/// positions of line breaks match upstream's string positions.
private struct SseLineBuffer {
    private var bytes: [UInt8] = []
    private var head = 0

    var isEmpty: Bool { head >= bytes.count }

    mutating func append(_ text: String) { bytes.append(contentsOf: text.utf8) }

    private func nextLineBreakIndex() -> Int {
        var i = head
        while i < bytes.count {
            if bytes[i] == CR || bytes[i] == LF { return i }
            i += 1
        }
        return -1
    }

    mutating func consumeLine() -> String? {
        let lineBreakIndex = nextLineBreakIndex()
        if lineBreakIndex == -1 {
            return nil
        }

        var nextIndex = lineBreakIndex + 1
        if bytes[lineBreakIndex] == CR && nextIndex < bytes.count && bytes[nextIndex] == LF {
            nextIndex += 1
        }

        let line = String(decoding: bytes[head..<lineBreakIndex], as: UTF8.self)
        head = nextIndex
        if head > 4096 && head * 2 > bytes.count {
            bytes.removeFirst(head)
            head = 0
        }
        return line
    }

    mutating func takeRest() -> String {
        let rest = String(decoding: bytes[head...], as: UTF8.self)
        bytes = []
        head = 0
        return rest
    }
}

/// `new TextDecoder()` with `decode(value, { stream: true })`: incomplete trailing UTF-8 sequences are
/// held until the next chunk; invalid bytes decode to U+FFFD.
private struct StreamingUtf8Decoder {
    private var pending: [UInt8] = []

    mutating func decode(_ data: Data, stream: Bool = true) -> String {
        pending.append(contentsOf: data)
        var cut = pending.count
        if stream {
            // Hold back an incomplete sequence at the end (at most 3 bytes).
            var i = pending.count - 1
            var continuation = 0
            while i >= 0 && continuation < 3 && (pending[i] & 0xC0) == 0x80 {
                continuation += 1
                i -= 1
            }
            if i >= 0 {
                let lead = pending[i]
                let expected = lead >= 0xF0 && lead <= 0xF4 ? 4 : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xC2 && lead <= 0xDF ? 2 : 1
                if expected > 1 && continuation + 1 < expected { cut = i }
            }
        }
        let text = String(decoding: pending[..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return text
    }

    /// `decoder.decode()`: flushes held bytes.
    mutating func finish() -> String { decode(Data(), stream: false) }
}

/// `async function* iterateSseMessages(body, signal)` as a pull-based iterator.
private struct SseMessageIterator {
    private var reader: ResponseBody.AsyncIterator
    private let signal: AbortSignal?
    private var decoder = StreamingUtf8Decoder()
    private var state = SseDecoderState(event: nil, data: [], raw: [])
    private var buffer = SseLineBuffer()
    private var queued: [ServerSentEvent] = []
    private var finished = false

    init(_ body: ResponseBody, _ signal: AbortSignal?) {
        self.reader = body.makeAsyncIterator()
        self.signal = signal
    }

    private mutating func drainLines() {
        while let line = buffer.consumeLine() {
            if let event = decodeSseLine(line, &state) {
                queued.append(event)
            }
        }
    }

    mutating func next() async throws -> ServerSentEvent? {
        while true {
            if !queued.isEmpty { return queued.removeFirst() }
            if finished { return nil }

            if signal?.aborted == true {
                throw PiError("Request was aborted")
            }

            guard let value = try await reader.next() else {
                buffer.append(decoder.finish())
                drainLines()

                if !buffer.isEmpty {
                    if let event = decodeSseLine(buffer.takeRest(), &state) {
                        queued.append(event)
                    }
                }

                if let trailingEvent = flushSseEvent(&state) {
                    queued.append(trailingEvent)
                }
                finished = true
                continue
            }

            buffer.append(decoder.decode(value))
            drainLines()
        }
    }
}

/// `async function* iterateAnthropicEvents(response, signal)` as a pull-based iterator.
private struct AnthropicEventIterator {
    private var sseMessages: SseMessageIterator
    private var sawMessageStart = false
    private var sawMessageEnd = false

    init(_ response: FetchResponse, _ signal: AbortSignal?) {
        // Not ported: the `!response.body` check ("Attempted to iterate over an Anthropic response with no
        // body"); a Swift `FetchResponse` always has a body.
        sseMessages = SseMessageIterator(response.body, signal)
    }

    mutating func next() async throws -> JsonValue? {
        while let sse = try await sseMessages.next() {
            if sse.event == "error" {
                throw PiError(sse.data)
            }

            if !ANTHROPIC_MESSAGE_EVENTS.contains(sse.event ?? "") {
                continue
            }

            do {
                let event = try parseJsonWithRepair(sse.data)
                let type = try prop(event, "type")
                if type == "message_start" {
                    sawMessageStart = true
                } else if type == "message_stop" {
                    sawMessageEnd = true
                }
                return event
            } catch {
                let message = errorMessage(error)
                throw PiError(
                    "Could not parse Anthropic SSE event \(sse.event ?? "null"): \(message); data=\(sse.data); raw=\(sse.raw.joined(separator: "\\n"))"
                )
            }
        }

        if sawMessageStart && !sawMessageEnd {
            throw PiError("Anthropic stream ended before message_stop")
        }
        return nil
    }
}

/// JS property read on a parsed event: reading from `undefined`/`null` throws the V8 TypeError.
private func prop(_ value: JsonValue?, _ key: String) throws -> JsonValue? {
    switch value {
    case nil:
        throw PiError("Cannot read properties of undefined (reading '\(key)')", name: "TypeError")
    case .null?:
        throw PiError("Cannot read properties of null (reading '\(key)')", name: "TypeError")
    case .object(let object)?:
        return object[key]
    default:
        return nil
    }
}

/// `value || 0` for a token count.
private func tokensOrZero(_ value: JsonValue?) -> Int {
    guard let number = value?.doubleValue, number.isFinite else { return 0 }
    return Int(number)
}

/// `value != null` read of a token count.
private func tokensIfPresent(_ value: JsonValue?) -> Int? {
    guard let value, !value.isNull else { return nil }
    return Int(value.doubleValue ?? 0)
}

/// Streams one Anthropic Messages response (upstream `stream`).
public func streamAnthropicMessages(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: AnthropicOptions? = nil
) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let normalizedContext = resolveTranscript(context, getAnthropicCompat(model).supportsMidConvoSystemMessages)
    let currentTools = getCurrentTools(normalizedContext.messages)

    Task {
        var output = AssistantMessage(
            content: [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                totalTokens: 0,
                cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
            ),
            stopReason: .pending,
            timestamp: dateNow()
        )

        do {
            let client: Anthropic
            let isOAuth: Bool
            var usageModel = model
            var inputTransformations: [JsonValue]?

            if let injected = options?.client {
                client = injected
                isOAuth = false
            } else {
                let apiKey = options?.apiKey
                let federation = getAnthropicFederation(model, apiKey, options?.headers, options?.env)
                if federation == nil { try assertRequestAuth(model.provider, apiKey, options?.headers) }

                var copilotDynamicHeaders: [(String, String)]?
                if model.provider == "github-copilot" {
                    let hasImages = hasCopilotVisionInput(normalizedContext.messages)
                    copilotDynamicHeaders = buildCopilotDynamicHeaders(
                        messages: normalizedContext.messages,
                        hasImages: hasImages
                    )
                }

                let cacheRetention = resolveCacheRetention(options?.cacheRetention, options?.env)
                let cacheSessionId = cacheRetention == .none ? nil : options?.sessionId

                let created = try createClient(
                    model,
                    apiKey,
                    options?.headers,
                    options?.fetch,
                    copilotDynamicHeaders,
                    cacheSessionId,
                    federation,
                    options?.identity
                )
                client = created.client
                isOAuth = created.isOAuthToken
            }
            let requestOptions = RequestOptions(
                signal: options?.signal,
                timeout: options?.timeoutMs,
                maxRetries: 0
            )
            var disablePreferredStrictTools = false
            var response: FetchResponse
            while true {
                try options?.signal?.throwIfAborted()
                let built = try buildParams(model, normalizedContext, isOAuth, options, disablePreferredStrictTools)
                if let providerThinkingLevel = built.providerThinkingLevel { output.providerThinkingLevel = providerThinkingLevel.rawValue }
                var params = built.params
                let nextParams = try await options?.onPayload?(.object(params), model)
                if let nextParams {
                    params = nextParams.objectValue ?? JsonObject()
                    params["stream"] = true
                }
                do {
                    let requestParams = params
                    response = try await retryProviderRequest(
                        { try await client.beta.messages.create(.object(requestParams), requestOptions).asResponse() },
                        ProviderRetryOptions(
                            maxRetries: options?.maxRetries,
                            maxRetryDelayMs: options?.maxRetryDelayMs,
                            signal: options?.signal
                        )
                    )
                    break
                } catch {
                    // Only downgrade a rejected request, never an already-started stream.
                    guard
                        options?.signal?.aborted != true,
                        !disablePreferredStrictTools,
                        built.hasPreferredStrictTools,
                        let apiError = error as? Anthropic.APIError,
                        apiError.status == 400,
                        apiError.type == "invalid_request_error",
                        [
                            "The compiled grammar is too large",
                            "Too many strict tools (",
                            "Schemas contains too many parameters with union types (",
                        ].contains(where: { apiError.message.contains($0) })
                    else {
                        throw error
                    }
                    disablePreferredStrictTools = true
                    appendAssistantMessageDiagnostic(&output, AssistantMessageDiagnostic(
                        type: "anthropic_strict_tools_fallback",
                        timestamp: dateNow(),
                        error: DiagnosticErrorInfo(message: apiError.message),
                        details: ["reason": "strict_tool_limits_exceeded"]
                    ))
                }
            }
            try await options?.onResponse?(ProviderResponse(status: response.status, headers: headersToRecord(response.headers)), model)
            stream.push(.start(partial: output))

            // `Block = (ThinkingContent | TextContent | (ToolCall & { partialJson })) & { index }`:
            // `blockIndices[i]` is the stream index of `output.content[i]` (nil once deleted);
            // `toolArguments[i]` the incremental arguments of a tool call.
            var blockIndices: [JsonValue?] = []
            var toolArguments: [Int: ToolCallArgumentsStream] = [:]
            func findBlock(_ index: JsonValue?) -> Int {
                blockIndices.firstIndex { $0 == index } ?? -1
            }

            var events = AnthropicEventIterator(response, options?.signal)
            while let event = try await events.next() {
                await options?.onProviderStreamEvent?(event, model)
                let type = try prop(event, "type")
                if type == "message_start" {
                    let message = try prop(event, "message")
                    output.responseId = try prop(message, "id")?.stringValue
                    let transformations = try prop(message, "input_transformations")
                    if case .array(let array)? = transformations { inputTransformations = array }
                    let responseModel = try prop(message, "model")?.stringValue
                    if responseModel != model.id { output.responseModel = responseModel }
                    let fallbackCost: ModelCost? =
                        responseModel == model.id
                            ? nil
                            : AnthropicMessagesCompat(json: model.compat).allowedFallbackModels?.first {
                                $0.provider == model.provider && $0.model == responseModel
                            }?.cost
                    if let fallbackCost, let responseModel {
                        var fallback = model
                        fallback.id = responseModel
                        fallback.cost = fallbackCost
                        usageModel = fallback
                    } else {
                        usageModel = model
                    }
                    // Capture initial token usage from message_start event
                    // This ensures we have input token counts even if the stream is aborted early
                    let usage = try prop(message, "usage")
                    output.usage.input = tokensOrZero(try prop(usage, "input_tokens"))
                    output.usage.output = tokensOrZero(try prop(usage, "output_tokens"))
                    output.usage.cacheRead = tokensOrZero(try prop(usage, "cache_read_input_tokens"))
                    output.usage.cacheWrite = tokensOrZero(try prop(usage, "cache_creation_input_tokens"))
                    let cacheCreation = try prop(usage, "cache_creation")
                    output.usage.cacheWrite1h = cacheCreation == nil || cacheCreation == .null
                        ? 0
                        : tokensOrZero(try prop(cacheCreation, "ephemeral_1h_input_tokens"))
                    // Anthropic doesn't provide total_tokens, compute from components
                    output.usage.totalTokens =
                        output.usage.input + output.usage.output + output.usage.cacheRead + output.usage.cacheWrite
                    calculateCost(usageModel, &output.usage)
                } else if type == "content_block_start" {
                    let contentBlock = try prop(event, "content_block")
                    let blockType = try prop(contentBlock, "type")
                    let index = try prop(event, "index")
                    if blockType == "fallback" {
                        if output.content.count > 0 {
                            throw PiError("Anthropic performed an unsupported mid-output model fallback")
                        }
                        continue
                    }
                    if blockType == "text" {
                        output.content.append(.text(TextContent(
                            text: try prop(contentBlock, "text")?.stringValue ?? ""
                        )))
                        blockIndices.append(index)
                        stream.push(.textStart(contentIndex: output.content.count - 1, partial: output))
                    } else if blockType == "thinking" {
                        output.content.append(.thinking(ThinkingContent(
                            thinking: try prop(contentBlock, "thinking")?.stringValue ?? "",
                            thinkingSignature: try prop(contentBlock, "signature")?.stringValue ?? ""
                        )))
                        blockIndices.append(index)
                        stream.push(.thinkingStart(contentIndex: output.content.count - 1, partial: output))
                    } else if blockType == "redacted_thinking" {
                        output.content.append(.thinking(ThinkingContent(
                            thinking: "[Reasoning redacted]",
                            thinkingSignature: try prop(contentBlock, "data")?.stringValue,
                            redacted: true
                        )))
                        blockIndices.append(index)
                        stream.push(.thinkingStart(contentIndex: output.content.count - 1, partial: output))
                    } else if blockType == "tool_use" {
                        let name = try prop(contentBlock, "name")?.stringValue ?? ""
                        output.content.append(.toolCall(ToolCall(
                            id: try prop(contentBlock, "id")?.stringValue ?? "",
                            name: isOAuth
                                ? fromClaudeCodeName(name, currentTools)
                                : name,
                            arguments: try prop(contentBlock, "input")?.objectValue ?? JsonObject()
                        )))
                        blockIndices.append(index)
                        toolArguments[output.content.count - 1] = ToolCallArgumentsStream()
                        stream.push(.toolcallStart(contentIndex: output.content.count - 1, partial: output))
                    }
                } else if type == "content_block_delta" {
                    let delta = try prop(event, "delta")
                    let deltaType = try prop(delta, "type")
                    if deltaType == "text_delta" {
                        let index = findBlock(try prop(event, "index"))
                        if index >= 0, case .text(var block) = output.content[index] {
                            let text = try prop(delta, "text")?.stringValue ?? ""
                            block.text += text
                            output.content[index] = .text(block)
                            stream.push(.textDelta(
                                contentIndex: index,
                                delta: text,
                                partial: output
                            ))
                        }
                    } else if deltaType == "thinking_delta" {
                        let index = findBlock(try prop(event, "index"))
                        if index >= 0, case .thinking(var block) = output.content[index] {
                            let thinking = try prop(delta, "thinking")?.stringValue ?? ""
                            block.thinking += thinking
                            output.content[index] = .thinking(block)
                            stream.push(.thinkingDelta(
                                contentIndex: index,
                                delta: thinking,
                                partial: output
                            ))
                        }
                    } else if deltaType == "input_json_delta" {
                        let index = findBlock(try prop(event, "index"))
                        if index >= 0, case .toolCall(var block) = output.content[index] {
                            let partial = try prop(delta, "partial_json")?.stringValue ?? ""
                            block.arguments = toolArguments[index]?.append(partial) ?? JsonObject()
                            output.content[index] = .toolCall(block)
                            stream.push(.toolcallDelta(
                                contentIndex: index,
                                delta: partial,
                                partial: output
                            ))
                        }
                    } else if deltaType == "signature_delta" {
                        let index = findBlock(try prop(event, "index"))
                        if index >= 0, case .thinking(var block) = output.content[index] {
                            block.thinkingSignature = (block.thinkingSignature ?? "").isEmpty ? "" : block.thinkingSignature
                            block.thinkingSignature! += try prop(delta, "signature")?.stringValue ?? ""
                            output.content[index] = .thinking(block)
                        }
                    }
                } else if type == "content_block_stop" {
                    let index = findBlock(try prop(event, "index"))
                    if index >= 0 {
                        blockIndices[index] = nil
                        switch output.content[index] {
                        case .text(let block):
                            stream.push(.textEnd(
                                contentIndex: index,
                                content: block.text,
                                partial: output
                            ))
                        case .thinking(let block):
                            stream.push(.thinkingEnd(
                                contentIndex: index,
                                content: block.thinking,
                                partial: output
                            ))
                        case .toolCall(var block):
                            let parsed = toolArguments[index]?.finish() ?? ParsedToolCallArguments(arguments: JsonObject())
                            block.arguments = parsed.arguments
                            block.argumentsError = parsed.argumentsError
                            output.content[index] = .toolCall(block)
                            // Finalize in-place and strip the scratch buffer so replay only
                            // carries parsed arguments.
                            toolArguments[index] = nil
                            stream.push(.toolcallEnd(
                                contentIndex: index,
                                toolCall: block,
                                partial: output
                            ))
                        }
                    }
                } else if type == "message_delta" {
                    let transformations = try prop(event, "input_transformations")
                    if case .array(let array)? = transformations { inputTransformations = array }
                    let delta = try prop(event, "delta")
                    if case .string(let stopReason)? = try prop(delta, "stop_reason"), !stopReason.isEmpty {
                        output.rawStopReason = stopReason
                        let stopReasonResult = try mapStopReason(stopReason, try prop(delta, "stop_details"))
                        output.stopReason = stopReasonResult.stopReason
                        if let errorMessage = stopReasonResult.errorMessage, !errorMessage.isEmpty {
                            output.errorMessage = errorMessage
                        }
                    }
                    // Only update usage fields if present (not null).
                    // Preserves input_tokens from message_start when proxies omit it in message_delta.
                    if let usage = try prop(event, "usage"), jsTruthy(usage) {
                        if let input = tokensIfPresent(try prop(usage, "input_tokens")) {
                            output.usage.input = input
                        }
                        if let outputTokens = tokensIfPresent(try prop(usage, "output_tokens")) {
                            output.usage.output = outputTokens
                        }
                        if let cacheRead = tokensIfPresent(try prop(usage, "cache_read_input_tokens")) {
                            output.usage.cacheRead = cacheRead
                        }
                        if let cacheWrite = tokensIfPresent(try prop(usage, "cache_creation_input_tokens")) {
                            output.usage.cacheWrite = cacheWrite
                        }
                        // Vercel AI Gateway includes the TTL breakdown in deltas, though the SDK only types it on message_start.
                        let cacheCreation = try prop(usage, "cache_creation")
                        if cacheCreation != nil && cacheCreation != .null,
                           let cacheWrite1h = tokensIfPresent(try prop(cacheCreation, "ephemeral_1h_input_tokens")) {
                            output.usage.cacheWrite1h = cacheWrite1h
                        }
                        // Anthropic reports reasoning tokens as a subset of output tokens.
                        let details = try prop(usage, "output_tokens_details")
                        if details != nil && details != .null,
                           let thinkingTokens = tokensIfPresent(try prop(details, "thinking_tokens")) {
                            output.usage.reasoning = thinkingTokens
                        }
                    }
                    // Anthropic doesn't provide total_tokens, compute from components
                    output.usage.totalTokens =
                        output.usage.input + output.usage.output + output.usage.cacheRead + output.usage.cacheWrite
                    calculateCost(usageModel, &output.usage)
                }
            }

            if options?.signal?.aborted == true {
                throw PiError("Request was aborted")
            }

            if output.stopReason == .pending {
                throw PiError("Anthropic stream ended without a stop reason")
            }
            if output.stopReason == .aborted || output.stopReason == .error {
                throw PiError((output.errorMessage ?? "").isEmpty ? "An unknown error occurred" : output.errorMessage!)
            }
            if let inputTransformations, inputTransformations.count > 0 {
                appendAssistantMessageDiagnostic(&output, AssistantMessageDiagnostic(
                    type: "anthropic_input_transformations",
                    timestamp: dateNow(),
                    details: [
                        "transformations": .array(inputTransformations.map { transformation in
                            var entry = JsonObject()
                            for key in ["type", "path", "reason"] {
                                if let value = transformation[key], !value.isNull { entry[key] = value }
                            }
                            return .object(entry)
                        }),
                    ]
                ))
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            // Block `index` and `partialJson` live in side tables and are never persisted.
            output.stopReason = options?.signal?.aborted == true ? .aborted : .error
            output.errorMessage = errorMessage(error)
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

/**
 * Map ThinkingLevel to Anthropic effort levels for adaptive thinking.
 * Note: effort "max" is available on all adaptive-thinking Claude models, while native
 * "xhigh" is only available on Opus 4.7/4.8, Sonnet 5, and Fable 5.
 */
private func mapThinkingLevelToEffort(_ model: Model, _ level: ThinkingLevel?) -> AnthropicEffort {
    let mapped: String?? = level.flatMap { model.thinkingLevelMap?[ModelThinkingLevel($0)] }
    if case .some(.some(let value)) = mapped { return AnthropicEffort(rawValue: value) }

    switch level {
    case .minimal, .low:
        return .low
    case .medium:
        return .medium
    case .high:
        return .high
    default:
        return .high
    }
}

/// Simple-options entry point (upstream `streamSimple`).
public func streamSimpleAnthropicMessages(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: SimpleStreamOptions? = nil
) -> AssistantMessageEventStream {
    if getAnthropicFederation(model, options?.apiKey, options?.headers, options?.env) == nil {
        do {
            try assertRequestAuth(model.provider, options?.apiKey, options?.headers)
        } catch {
            // Upstream throws synchronously; a Swift `StreamFunction` cannot throw, so the error ends the
            // stream the way `lazyStream` reports a setup failure.
            return createThrownStreamError(model, error)
        }
    }

    var base = AnthropicOptions(buildBaseOptions(model, context, options, options?.apiKey))
    base.toolChoice = options?.toolChoice.map(AnthropicToolChoice.type)
    guard let reasoning = options?.reasoning else {
        var next = base
        next.thinkingEnabled = false
        return streamAnthropicMessages(model, context, next)
    }

    // For models with adaptive thinking: use an effort level.
    // For older models: use budget-based thinking.
    if AnthropicMessagesCompat(json: model.compat).forceAdaptiveThinking == true {
        let effort = mapThinkingLevelToEffort(model, reasoning)
        var next = base
        next.thinkingEnabled = true
        next.effort = effort
        return streamAnthropicMessages(model, context, next)
    }

    // Undefined means the caller did not request an output cap; let the helper use the model cap.
    // Do not coerce to 0 here, or the thinking budget would become the entire max_tokens value.
    let adjusted = adjustMaxTokensForThinking(
        base.maxTokens,
        model.maxTokens,
        reasoning,
        options?.thinkingBudgets
    )

    let maxTokens = clampMaxTokensToContext(model, context, adjusted.maxTokens)

    var next = base
    next.maxTokens = maxTokens
    next.thinkingEnabled = true
    next.thinkingBudgetTokens = min(adjusted.thinkingBudget, max(0, maxTokens - 1024))
    return streamAnthropicMessages(model, context, next)
}

/// The error stream `lazyStream` produces when setup throws (`createSetupErrorMessage`).
private func createThrownStreamError(_ model: Model, _ error: any Error) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(),
        stopReason: .error,
        errorMessage: errorMessage(error),
        timestamp: dateNow()
    )
    stream.push(.error(reason: .error, error: message))
    stream.end(message)
    return stream
}

private func isOAuthToken(_ apiKey: String) -> Bool {
    apiKey.contains("sk-ant-oat")
}

private func providerHeaders(_ headers: [(String, String)]?) -> ProviderHeaders? {
    headers?.map { ($0.0, Optional($0.1)) }
}

private func createClient(
    _ model: Model,
    _ apiKey: String?,
    _ optionsHeaders: ProviderHeaders? = nil,
    _ fetch: FetchFunction? = nil,
    _ dynamicHeaders: [(String, String)]? = nil,
    _ sessionId: String? = nil,
    _ federation: AnthropicFederationConfig? = nil,
    _ identity: ClientIdentity? = nil
) throws -> (client: Anthropic, isOAuthToken: Bool) {
    // Copilot: Bearer auth.
    if model.provider == "github-copilot" {
        let client = try PiAnthropic(Anthropic.ClientOptions(
            apiKey: .some(nil),
            authToken: .some(apiKey),
            baseURL: model.baseUrl,
            fetch: fetch,
            defaultHeaders: .record(mergeClientHeaders(
                getIdentityHeaders(.init(model), identity),
                [
                    ("accept", "application/json"),
                    ("anthropic-dangerous-direct-browser-access", "true"),
                ],
                providerHeaders(model.headers),
                providerHeaders(dynamicHeaders),
                optionsHeaders
            )),
            dangerouslyAllowBrowser: true
        ))

        return (client, false)
    }

    // OAuth: Bearer auth, Claude Code identity headers
    if let apiKey, isOAuthToken(apiKey) {
        let client = try PiAnthropic(Anthropic.ClientOptions(
            apiKey: .some(nil),
            authToken: .some(apiKey),
            baseURL: model.baseUrl,
            fetch: fetch,
            defaultHeaders: .record(mergeClientHeaders(
                getIdentityHeaders(.init(model), identity),
                [
                    ("accept", "application/json"),
                    ("anthropic-dangerous-direct-browser-access", "true"),
                    ("user-agent", "claude-cli/\(claudeCodeVersion)"),
                    ("x-app", "cli"),
                ],
                providerHeaders(model.headers),
                optionsHeaders
            )),
            dangerouslyAllowBrowser: true
        ))

        return (client, true)
    }

    // API key, header-owned auth, or workload identity federation.
    let compat = getAnthropicCompat(model)
    var sessionAffinityHeaders: ProviderHeaders = []
    if let sessionId, !sessionId.isEmpty, compat.sendSessionAffinityHeaders {
        let header = compat.sessionAffinityFormat == .openrouter ? "x-session-id" : "x-session-affinity"
        sessionAffinityHeaders.append((header, sessionId))
    }
    let defaultHeaders = mergeClientHeaders(
        getIdentityHeaders(.init(model), identity),
        [
            ("accept", "application/json"),
            ("anthropic-dangerous-direct-browser-access", "true"),
        ],
        sessionAffinityHeaders,
        providerHeaders(model.headers),
        optionsHeaders
    )
    if let federation {
        let key = JsonValue.array([.string(model.baseUrl), federationConfigJson(federation)]).serialized()
        let cached = federationClient.withLock { $0 }
        let base: Anthropic
        if let cached, cached.key == key, sameFetch(cached.fetch, fetch) {
            base = cached.client
        } else {
            let client = try PiAnthropic(Anthropic.ClientOptions(
                apiKey: .some(nil),
                authToken: .some(nil),
                baseURL: model.baseUrl,
                fetch: fetch,
                dangerouslyAllowBrowser: true,
                config: federation
            ))
            federationClient.withLock { $0 = (key, fetch, client) }
            base = client
        }
        return (try base.withOptions(Anthropic.ClientOptions(defaultHeaders: .record(defaultHeaders))), false)
    }

    let client = try PiAnthropic(Anthropic.ClientOptions(
        apiKey: .some(apiKey),
        authToken: .some(nil),
        baseURL: model.baseUrl,
        fetch: fetch,
        defaultHeaders: .record(defaultHeaders),
        dangerouslyAllowBrowser: true
    ))

    return (client, false)
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

private func getBetaFeatures(
    _ model: Model,
    _ context: TranscriptContext,
    _ isOAuthToken: Bool,
    _ nativeToolChanges: Bool,
    _ options: AnthropicOptions? = nil
) -> [String] {
    // undefined: none configured; .some(nil): explicit null (suppression).
    var configuredFeatures: String??
    for headers in [providerHeaders(model.headers), options?.headers] {
        for (name, value) in headers ?? [] {
            if name.lowercased() == "anthropic-beta" { configuredFeatures = .some(value) }
        }
    }
    if case .some(.none) = configuredFeatures { return [] }
    if case .some(.some(let configured)) = configuredFeatures {
        return uniqueStrings(
            configured
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { jsTrim(String($0)) }
                .filter { $0.count > 0 }
        )
    }

    let compat = AnthropicMessagesCompat(json: model.compat)
    var features: [String] = []
    if isOAuthToken { features.append(contentsOf: ["claude-code-20250219", "oauth-2025-04-20"]) }
    if shouldUseFineGrainedToolStreamingBeta(model, context) { features.append(FINE_GRAINED_TOOL_STREAMING_BETA) }
    if model.reasoning &&
        options?.thinkingEnabled == true &&
        (options?.interleavedThinking ?? true) &&
        compat.forceAdaptiveThinking != true
    {
        features.append(INTERLEAVED_THINKING_BETA)
    }
    if shouldUseServerSideFallbackBeta(model) { features.append(SERVER_SIDE_FALLBACK_BETA) }
    if compat.supportsMidConvoEffort == true {
        features.append(contentsOf: [MID_CONVERSATION_OUTPUT_CONFIG_BETA, THINKING_BINDING_CONTROLS_BETA])
    }
    if nativeToolChanges { features.append(INLINE_TOOLS_BETA) }
    return uniqueStrings(features)
}

private struct BuiltParams {
    var params: JsonObject
    var hasPreferredStrictTools: Bool
    /** Effort of the final effort marker, recorded on the reply so later requests can replay it. */
    var providerThinkingLevel: AnthropicEffort?
}

private func buildParams(
    _ model: Model,
    _ context: TranscriptContext,
    _ isOAuthToken: Bool,
    _ options: AnthropicOptions? = nil,
    _ disablePreferredStrictTools: Bool = false
) throws -> BuiltParams {
    let cacheControl = getCacheControl(model, options?.cacheRetention, options?.env).cacheControl
    let compat = getAnthropicCompat(model)
    let modelCompat = AnthropicMessagesCompat(json: model.compat)
    let initialSystemMessage = getInitialSystemMessage(context.messages)
    let initialSystemText = initialSystemMessage.map(getSystemMessageText) ?? ""
    let transformedMessages = transformMessages(context.messages, model, { id, _, _ in normalizeToolCallId(id) })
    let conversationMessages = initialSystemMessage != nil ? Array(transformedMessages.dropFirst()) : transformedMessages
    // Native tool changes keep the request-level tool list fixed and define every later tool
    // by value in a `tool_addition` block, which also expresses same-name redefinitions.
    // Anthropic rejects a tool list where every tool is deferred, so there must be an initial
    // active tool to anchor the placeholder. Otherwise the current tool list is sent.
    var hasPreferredStrictTools = false
    let convertToolDefinitions = { (tools: [Tool], toolCacheControl: CacheControlEphemeral?) throws -> [JsonObject] in
        let definitions = try convertTools(
            tools,
            isOAuthToken,
            compat.supportsEagerToolInputStreaming,
            compat.supportsStrictTools,
            toolCacheControl,
            disablePreferredStrictTools
        )
        if definitions.enumerated().contains(where: { index, definition in
            guard case .some(.some(.jsonSchema(let strict))) = tools[index].constrainedSampling else { return false }
            return definition["strict"] == true && strict == "prefer"
        }) {
            hasPreferredStrictTools = true
        }
        return definitions
    }
    let initialTools = initialSystemMessage?.toolsAdded ?? []
    let nativeToolChanges =
        compat.supportsMidConvoSystemMessages && compat.supportsMidConvoToolChanges && initialTools.count > 0
    let offIsNull: Bool = {
        if let map = model.thinkingLevelMap, let entry = map[.off], entry == nil { return true }
        return false
    }()
    let thinkingDisabled =
        model.reasoning && options?.thinkingEnabled == false && !offIsNull
    // Effort cannot change between messages while thinking is disabled, so "off" sends no effort markers.
    let effortMessages = modelCompat.supportsMidConvoEffort == true && !thinkingDisabled
    let converted = try convertMessages(
        conversationMessages,
        isOAuthToken,
        cacheControl,
        compat.allowEmptySignature,
        effortMessages ? model.provider : nil,
        nativeToolChanges ? { tools in try convertToolDefinitions(tools, nil) } : nil
    )
    let activeEffort = options?.effort ?? .high
    let betaFeatures = getBetaFeatures(model, context, isOAuthToken, nativeToolChanges, options)
    var params: JsonObject = [
        "model": .string(model.id),
        "messages": .array((effortMessages ? insertThinkingLevelMessages(converted, activeEffort) : converted.messages).map(JsonValue.object)),
        "max_tokens": .number(Double(options?.maxTokens ?? model.maxTokens)),
        "stream": true,
    ]
    if betaFeatures.count > 0 { params["betas"] = .array(betaFeatures.map(JsonValue.string)) }

    func systemBlock(_ text: String) -> JsonValue {
        var block: JsonObject = ["type": "text", "text": .string(text)]
        if let cacheControl { block["cache_control"] = .object(cacheControl) }
        return .object(block)
    }

    // For OAuth tokens, we MUST include Claude Code identity
    if isOAuthToken {
        var system: [JsonValue] = [systemBlock("You are Claude Code, Anthropic's official CLI for Claude.")]
        if !initialSystemText.isEmpty {
            system.append(systemBlock(sanitizeSurrogates(initialSystemText)))
        }
        params["system"] = .array(system)
    } else if !initialSystemText.isEmpty {
        // Add cache control to system prompt for non-OAuth tokens
        params["system"] = .array([systemBlock(sanitizeSurrogates(initialSystemText))])
    }

    // Temperature is incompatible with extended thinking and unsupported on Claude Opus 4.7+.
    if let temperature = options?.temperature,
       options?.thinkingEnabled != true,
       modelCompat.supportsMidConvoEffort != true,
       compat.supportsTemperature
    {
        params["temperature"] = .number(temperature)
    }

    let toolCacheControl = compat.supportsCacheControlOnTools ? cacheControl : nil
    if nativeToolChanges {
        // Initial tools stay active with the cache breakpoint on the last one, followed by the
        // placeholder. The list never changes afterwards: later tools are defined by value in
        // `tool_addition` blocks and withdrawn by `tool_removal`, so the cached prefix survives
        // every tool change.
        params["tools"] = .array((try convertToolDefinitions(initialTools, toolCacheControl) + [DEFERRED_TOOL_PLACEHOLDER]).map(JsonValue.object))
    } else {
        let tools = getCurrentTools(context.messages)
        if tools.count > 0 {
            params["tools"] = .array(try convertToolDefinitions(tools, toolCacheControl).map(JsonValue.object))
        }
    }

    if thinkingDisabled {
        // No effort is sent, so the model default applies. Anthropic rejects `block_binding`
        // with disabled thinking.
        params["thinking"] = ["type": "disabled"]
    } else if effortMessages {
        // Managed effort models use adaptive thinking so prefix mismatches can
        // be dropped instead of surfacing as persistent 400 responses.
        params["thinking"] = [
            "type": "adaptive",
            "display": .string((options?.thinkingDisplay ?? .summarized).rawValue),
            "block_binding": ["prefix_mismatch_behavior": "drop_block"],
        ]
        params["output_config"] = ["effort": "high"]
    } else if model.reasoning, let options, options.thinkingEnabled == true {
        // Default to "summarized" so Opus 4.7 and Mythos Preview behave like
        // older Claude 4 models (whose API default is also "summarized").
        let display: AnthropicThinkingDisplay = options.thinkingDisplay ?? .summarized
        if modelCompat.forceAdaptiveThinking == true {
            // Adaptive thinking: Claude decides when and how much to think.
            params["thinking"] = ["type": "adaptive", "display": .string(display.rawValue)]
            if let effort = options.effort {
                params["output_config"] = ["effort": .string(effort.rawValue)]
            }
        } else {
            // Budget-based thinking for older models
            let budget = options.thinkingBudgetTokens ?? 0
            params["thinking"] = [
                "type": "enabled",
                "budget_tokens": .number(Double(budget != 0 ? budget : 1024)),
                "display": .string(display.rawValue),
            ]
        }
    }

    if let metadata = options?.metadata {
        if case .string(let userId)? = metadata["user_id"] {
            params["metadata"] = ["user_id": .string(userId)]
        }
    }

    if let toolChoice = options?.toolChoice {
        switch toolChoice {
        case .type(let type):
            params["tool_choice"] = ["type": .string(type)]
        case .tool(let name):
            params["tool_choice"] = ["type": "tool", "name": .string(name)]
        }
    }

    if let allowedFallbackModels = modelCompat.allowedFallbackModels, allowedFallbackModels.count > 0 {
        params["fallbacks"] = .array(allowedFallbackModels.map { ["model": .string($0.model)] })
    }

    return BuiltParams(params: params, hasPreferredStrictTools: hasPreferredStrictTools, providerThinkingLevel: effortMessages ? activeEffort : nil)
}

// Normalize tool call IDs to match Anthropic's required pattern and length
private func normalizeToolCallId(_ id: String) -> String {
    // `/[^a-zA-Z0-9_-]/g` without the `u` flag replaces UTF-16 code units; `slice(0, 64)` counts code units.
    let units = id.utf16.map { unit -> UInt16 in
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D: return unit
        default: return 0x5F
        }
    }
    return String(decoding: units.prefix(64), as: UTF16.self)
}

private func convertToolResult(_ msg: ToolResultMessage, _ content: [UserContent]? = nil) -> JsonObject {
    [
        "type": "tool_result",
        "tool_use_id": .string(msg.toolCallId),
        "content": convertContentBlocks(content ?? msg.content),
        "is_error": .bool(msg.isError),
    ]
}

private struct ConvertedAnthropicMessages {
    var messages: [JsonObject]
    var assistantLevels: [Int: AnthropicEffort]
}

private func convertMessages(
    _ transformedMessages: [Message],
    _ isOAuthToken: Bool,
    _ cacheControl: CacheControlEphemeral? = nil,
    _ allowEmptySignature: Bool = false,
    _ managedProvider: String? = nil,
    /** Converts tool definitions for native `tool_addition` blocks; undefined when tool changes are not native. */
    _ convertToolDefinitions: (([Tool]) throws -> [JsonObject])? = nil
) throws -> ConvertedAnthropicMessages {
    var params: [JsonObject] = []
    var assistantLevels: [Int: AnthropicEffort] = [:]
    // Later system messages are held back and emitted directly before the next assistant
    // message (or at the end of the transcript). Anthropic requires `tool_result` blocks to
    // immediately follow their `tool_use`, so a system message between them is rejected; this
    // also mirrors where the managed-effort system messages are inserted. As a result an
    // update placed before a user message in the transcript lands after it on the wire.
    var pendingSystemMessages: [JsonObject] = []
    func flushPendingSystemMessages() {
        params.append(contentsOf: pendingSystemMessages)
        pendingSystemMessages.removeAll()
    }

    var i = 0
    while i < transformedMessages.count {
        defer { i += 1 }
        let msg = transformedMessages[i]

        switch msg {
        case .system(let system):
            // Later system messages only reach this point when the model accepts them natively;
            // otherwise the transcript was collapsed into the leading message before conversion.
            let text = renderSystemMessageUpdate(system)
            var blocks: [JsonObject] = []
            if text.count > 0 { blocks.append(["type": "text", "text": .string(sanitizeSurrogates(text))]) }
            if let convertToolDefinitions {
                let added = system.toolsAdded ?? []
                let redefined = Set(added.map(\.name))
                for tool in system.toolsRemoved ?? [] {
                    // A new definition under the same name replaces the old one, so no removal is needed.
                    if redefined.contains(tool.name) { continue }
                    blocks.append([
                        "type": "tool_removal",
                        "tool": ["type": "tool_reference", "name": .string(isOAuthToken ? toClaudeCodeName(tool.name) : tool.name)],
                    ])
                }
                for definition in try convertToolDefinitions(added) {
                    blocks.append(["type": "tool_addition", "tool": ["type": "tool_definition", "definition": .object(definition)]])
                }
            }
            if blocks.count > 0 { pendingSystemMessages.append(["role": "system", "content": .array(blocks.map(JsonValue.object))]) }
        case .user(let user):
            switch user.content {
            case .string(let content):
                if jsTrim(content).count > 0 {
                    params.append([
                        "role": "user",
                        "content": .string(sanitizeSurrogates(content)),
                    ])
                }
            case .blocks(let content):
                let blocks: [JsonObject] = content.map { item in
                    if case .text(let text) = item {
                        return [
                            "type": "text",
                            "text": .string(sanitizeSurrogates(text.text)),
                        ]
                    } else {
                        return convertImageBlock(item.imageContent!)
                    }
                }
                let filteredBlocks = blocks.filter { b in
                    if b["type"] == "text" {
                        return jsTrim(b["text"]?.stringValue ?? "").count > 0
                    }
                    return true
                }
                if filteredBlocks.count == 0 { continue }
                params.append([
                    "role": "user",
                    "content": .array(filteredBlocks.map(JsonValue.object)),
                ])
            }
        case .assistant(let assistant):
            flushPendingSystemMessages()
            var blocks: [JsonObject] = []

            for block in assistant.content {
                switch block {
                case .text(let text):
                    if jsTrim(text.text).count == 0 { continue }
                    blocks.append([
                        "type": "text",
                        "text": .string(sanitizeSurrogates(text.text)),
                    ])
                case .thinking(let thinking):
                    // Redacted thinking: pass the opaque payload back as redacted_thinking
                    if thinking.redacted == true {
                        var redacted: JsonObject = ["type": "redacted_thinking"]
                        if let data = thinking.thinkingSignature { redacted["data"] = .string(data) }
                        blocks.append(redacted)
                        continue
                    }
                    let thinkingSignature = thinking.thinkingSignature
                    let hasThinkingSignature = thinkingSignature != nil && jsTrim(thinkingSignature!).count > 0
                    if jsTrim(thinking.thinking).count == 0 && !hasThinkingSignature { continue }
                    // If thinking signature is missing/empty (e.g., from aborted stream),
                    // convert to plain text for Anthropic. Some compatible providers emit
                    // and accept empty signatures, so let marked models preserve the block.
                    if !hasThinkingSignature {
                        blocks.append(
                            allowEmptySignature
                                ? [
                                    "type": "thinking",
                                    "thinking": .string(sanitizeSurrogates(thinking.thinking)),
                                    "signature": "",
                                ]
                                : [
                                    "type": "text",
                                    "text": .string(sanitizeSurrogates(thinking.thinking)),
                                ]
                        )
                    } else {
                        blocks.append([
                            "type": "thinking",
                            "thinking": .string(sanitizeSurrogates(thinking.thinking)),
                            "signature": .string(thinkingSignature!),
                        ])
                    }
                case .toolCall(let toolCall):
                    blocks.append([
                        "type": "tool_use",
                        "id": .string(toolCall.id),
                        "name": .string(isOAuthToken ? toClaudeCodeName(toolCall.name) : toolCall.name),
                        "input": .object(toolCall.arguments),
                    ])
                }
            }
            if blocks.count == 0 { continue }
            let messageIndex = params.count
            params.append([
                "role": "assistant",
                "content": .array(blocks.map(JsonValue.object)),
            ])
            if let managedProvider,
               assistant.api == "anthropic-messages",
               assistant.provider == managedProvider,
               let level = assistant.providerThinkingLevel,
               isAnthropicEffort(level)
            {
                assistantLevels[messageIndex] = AnthropicEffort(rawValue: level)
            }
        case .toolResult:
            // Collect all consecutive toolResult messages, needed for z.ai Anthropic endpoint.
            var toolResults: [JsonObject] = []
            // Anthropic rejects error tool results that contain anything but text, so their images follow
            // all tool results of the turn, which must come first in the user message (#10794).
            var errorImages: [JsonObject] = []
            var j = i
            while j < transformedMessages.count, case .toolResult(let toolMsg) = transformedMessages[j] {
                let split = splitErrorToolResultImages(toolMsg)
                toolResults.append(convertToolResult(toolMsg, split?.content.map(UserContent.text)))
                if let split {
                    errorImages.append(["type": "text", "text": .string(split.caption)])
                    errorImages.append(contentsOf: split.images.map(convertImageBlock))
                }
                j += 1
            }

            // Skip the messages we've already processed.
            i = j - 1

            params.append([
                "role": "user",
                "content": .array((toolResults + errorImages).map(JsonValue.object)),
            ])
        }
    }

    flushPendingSystemMessages()

    // Add cache_control to the last user or system message to cache conversation history
    if let cacheControl, params.count > 0 {
        var lastMessage = params[params.count - 1]
        if lastMessage["role"] == "user" || lastMessage["role"] == "system" {
            if case .array(var content)? = lastMessage["content"] {
                if var lastBlock = content.last?.objectValue,
                   ["text", "image", "tool_result", "tool_addition", "tool_removal"].contains(lastBlock["type"]?.stringValue ?? "")
                {
                    lastBlock["cache_control"] = .object(cacheControl)
                    content[content.count - 1] = .object(lastBlock)
                    lastMessage["content"] = .array(content)
                }
            } else if case .string(let text)? = lastMessage["content"] {
                lastMessage["content"] = [
                    [
                        "type": "text",
                        "text": .string(text),
                        "cache_control": .object(cacheControl),
                    ],
                ]
            }
            params[params.count - 1] = lastMessage
        }
    }

    return ConvertedAnthropicMessages(messages: params, assistantLevels: assistantLevels)
}

private func isAnthropicEffort(_ value: String?) -> Bool {
    value == "low" || value == "medium" || value == "high" || value == "xhigh" || value == "max"
}

private func insertThinkingLevelMessages(
    _ converted: ConvertedAnthropicMessages,
    _ activeEffort: AnthropicEffort
) -> [JsonObject] {
    var messages: [JsonObject] = []
    for index in converted.messages.indices {
        if let historicalEffort = converted.assistantLevels[index] {
            messages.append(["role": "system", "content": [], "output_config": ["effort": .string(historicalEffort.rawValue)]])
        }
        messages.append(converted.messages[index])
    }
    messages.append(["role": "system", "content": [], "output_config": ["effort": .string(activeEffort.rawValue)]])
    return messages
}

private func shouldUseFineGrainedToolStreamingBeta(
    _ model: Model,
    _ context: TranscriptContext
) -> Bool {
    getCurrentTools(context.messages).count > 0 && !getAnthropicCompat(model).supportsEagerToolInputStreaming
}

// Keywords Anthropic strict tool use rejects with a 400 for the whole request.
// https://platform.claude.com/docs/en/build-with-claude/structured-outputs#json-schema-limitations
private let ANTHROPIC_STRICT_UNSUPPORTED_KEYWORDS: Set<String> = [
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "multipleOf",
    "maxItems",
    "uniqueItems",
    "minContains",
    "maxContains",
    "minProperties",
    "maxProperties",
]
private let ANTHROPIC_STRICT_STRING_FORMATS: Set<String> = [
    "date-time",
    "time",
    "date",
    "duration",
    "email",
    "hostname",
    "uri",
    "ipv4",
    "ipv6",
    "uuid",
]

private let isAnthropicStrictUnsupportedKeyword: UnsupportedStrictSchemaKeywordCheck = { key, value in
    if ANTHROPIC_STRICT_UNSUPPORTED_KEYWORDS.contains(key) { return true }
    if key == "minItems" { return value != 0 && value != 1 }
    if key == "format" {
        guard case .string(let format) = value else { return true }
        return !ANTHROPIC_STRICT_STRING_FORMATS.contains(format)
    }
    return false
}

private func convertTools(
    _ tools: [Tool],
    _ isOAuthToken: Bool,
    _ supportsEagerToolInputStreaming: Bool,
    _ supportsStrictTools: Bool,
    _ cacheControl: CacheControlEphemeral? = nil,
    _ disablePreferredStrictTools: Bool = false
) throws -> [JsonObject] {
    try tools.enumerated().map { index, tool in
        let strict: Bool?
        if disablePreferredStrictTools, case .some(.some(.jsonSchema(let strictMode))) = tool.constrainedSampling, strictMode == "prefer" {
            strict = nil
        } else {
            strict = try resolveJsonSchemaStrictSampling(tool, supportsStrictTools, isAnthropicStrictUnsupportedKeyword)
        }
        let parameters = try getJsonSchemaToolParameters(tool, strict)
        let schema = parameters.objectValue ?? JsonObject()
        let legacyInputSchema: JsonObject = [
            "type": "object",
            "properties": schema["properties"].flatMap { $0.isNull ? nil : $0 } ?? .object(JsonObject()),
            "required": schema["required"].flatMap { $0.isNull ? nil : $0 } ?? .array([]),
        ]
        var inputSchema: JsonObject
        if strict == true {
            inputSchema = schema
            for (key, value) in legacyInputSchema { inputSchema[key] = value }
        } else {
            inputSchema = legacyInputSchema
        }

        var definition: JsonObject = [
            "name": .string(isOAuthToken ? toClaudeCodeName(tool.name) : tool.name),
            "description": .string(tool.description),
        ]
        if supportsEagerToolInputStreaming { definition["eager_input_streaming"] = true }
        if strict == true { definition["strict"] = true }
        definition["input_schema"] = .object(inputSchema)
        if let cacheControl, index == tools.count - 1 { definition["cache_control"] = .object(cacheControl) }
        return definition
    }
}

private func mapStopReason(
    _ reason: String,
    _ stopDetails: JsonValue? = nil
) throws -> (stopReason: StopReason, errorMessage: String?) {
    switch reason {
    case "end_turn":
        return (.stop, nil)
    case "max_tokens":
        return (.length, nil)
    case "tool_use":
        return (.toolUse, nil)
    case "refusal":
        let explanation = stopDetails?["explanation"]?.stringValue ?? ""
        return (
            .error,
            explanation.isEmpty ? "The model refused to complete the request" : explanation
        )
    case "pause_turn": // Stop is good enough -> resubmit
        return (.stop, nil)
    case "stop_sequence":
        return (.stop, nil) // We don't supply stop sequences, so this should never happen
    case "sensitive": // Content flagged by safety filters (not yet in SDK types)
        return (.error, "Provider stopped with: sensitive")
    default:
        // Handle unknown stop reasons gracefully (API may add new values)
        throw PiError("Unhandled stop reason: \(reason)")
    }
}
