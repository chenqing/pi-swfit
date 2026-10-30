// Port of packages/ai/src/providers/faux.ts
//
// Swift differences:
// - Upstream mutates shared closures/maps on JavaScript's single thread; here `FauxCore` keeps that state behind a lock.
// - `FauxProviderState` is passed to response factories as a snapshot (upstream passes the live object).
// - `queueMicrotask` becomes `Task.yield()`, `setTimeout` becomes `Task.sleep`.
// - `structuredClone` is unnecessary: messages are value types.
// - AssistantMessage.timestamp/usage are non-optional in Swift, so `cloneMessage` has no fallbacks to apply.

import Foundation

private let DEFAULT_API = "faux"
private let DEFAULT_PROVIDER = "faux"
private let DEFAULT_MODEL_ID = "faux-1"
private let DEFAULT_MODEL_NAME = "Faux Model"
private let DEFAULT_BASE_URL = "http://localhost:0"
private let DEFAULT_MIN_TOKEN_SIZE = 3
private let DEFAULT_MAX_TOKEN_SIZE = 5

private let DEFAULT_USAGE = Usage(
    input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
)

public struct FauxModelDefinition: Sendable {
    public var id: String
    public var name: String?
    public var reasoning: Bool?
    public var input: [ModelInputModality]?
    public var inputLimits: ModelInputLimits?
    public var cost: ModelCost?
    public var contextWindow: Int?
    public var maxTokens: Int?
    public init(id: String, name: String? = nil, reasoning: Bool? = nil, input: [ModelInputModality]? = nil, inputLimits: ModelInputLimits? = nil,
                cost: ModelCost? = nil, contextWindow: Int? = nil, maxTokens: Int? = nil) {
        self.id = id; self.name = name; self.reasoning = reasoning; self.input = input; self.inputLimits = inputLimits
        self.cost = cost; self.contextWindow = contextWindow; self.maxTokens = maxTokens
    }
}

/// `TextContent | ThinkingContent | ToolCall`.
public typealias FauxContentBlock = AssistantContent

public func fauxText(_ text: String) -> FauxContentBlock {
    .text(TextContent(text: text))
}

public func fauxThinking(_ thinking: String) -> FauxContentBlock {
    .thinking(ThinkingContent(thinking: thinking))
}

public func fauxToolCall(_ name: String, _ arguments: JsonObject, id: String? = nil) -> FauxContentBlock {
    .toolCall(ToolCall(id: id ?? randomId("tool"), name: name, arguments: arguments))
}

public func fauxAssistantMessage(
    _ content: String,
    stopReason: StopReason? = nil,
    deferred: DeferredHandle? = nil,
    errorMessage: String? = nil,
    responseId: String? = nil,
    timestamp: Int? = nil
) -> AssistantMessage {
    fauxAssistantMessage([fauxText(content)], stopReason: stopReason, deferred: deferred, errorMessage: errorMessage, responseId: responseId, timestamp: timestamp)
}

public func fauxAssistantMessage(
    _ content: FauxContentBlock,
    stopReason: StopReason? = nil,
    deferred: DeferredHandle? = nil,
    errorMessage: String? = nil,
    responseId: String? = nil,
    timestamp: Int? = nil
) -> AssistantMessage {
    fauxAssistantMessage([content], stopReason: stopReason, deferred: deferred, errorMessage: errorMessage, responseId: responseId, timestamp: timestamp)
}

public func fauxAssistantMessage(
    _ content: [FauxContentBlock],
    stopReason: StopReason? = nil,
    deferred: DeferredHandle? = nil,
    errorMessage: String? = nil,
    responseId: String? = nil,
    timestamp: Int? = nil
) -> AssistantMessage {
    var message = AssistantMessage(
        content: content,
        api: DEFAULT_API,
        provider: DEFAULT_PROVIDER,
        model: DEFAULT_MODEL_ID,
        usage: DEFAULT_USAGE,
        stopReason: stopReason ?? .stop,
        errorMessage: errorMessage,
        timestamp: timestamp ?? dateNow()
    )
    message.deferred = deferred
    message.responseId = responseId
    return message
}

public struct FauxProviderState: Sendable {
    public var callCount: Int
    public var deferredFetchCount: Int
    public var cancelledDeferred: [DeferredHandle]
    public init(callCount: Int = 0, deferredFetchCount: Int = 0, cancelledDeferred: [DeferredHandle] = []) {
        self.callCount = callCount; self.deferredFetchCount = deferredFetchCount; self.cancelledDeferred = cancelledDeferred
    }
}

public typealias FauxResponseFactory = @Sendable (
    _ context: TranscriptContext,
    _ options: SimpleStreamOptions?,
    _ state: FauxProviderState,
    _ model: Model
) async throws -> AssistantMessage

public enum FauxResponseStep: Sendable {
    case message(AssistantMessage)
    case factory(FauxResponseFactory)
}

public struct RegisterFauxProviderOptions: Sendable {
    public struct Deferred: Sendable {
        /// Number of fetches that return the original handle before the scripted response becomes ready.
        public var pendingFetches: Int?
        public var pollAfterMs: Int?
        public init(pendingFetches: Int? = nil, pollAfterMs: Int? = nil) { self.pendingFetches = pendingFetches; self.pollAfterMs = pollAfterMs }
    }
    public struct TokenSize: Sendable {
        public var min: Int?
        public var max: Int?
        public init(min: Int? = nil, max: Int? = nil) { self.min = min; self.max = max }
    }
    public var api: String?
    public var provider: String?
    public var models: [FauxModelDefinition]?
    public var deferred: Deferred?
    public var tokensPerSecond: Double?
    public var tokenSize: TokenSize?
    public init(api: String? = nil, provider: String? = nil, models: [FauxModelDefinition]? = nil, deferred: Deferred? = nil,
                tokensPerSecond: Double? = nil, tokenSize: TokenSize? = nil) {
        self.api = api; self.provider = provider; self.models = models; self.deferred = deferred
        self.tokensPerSecond = tokensPerSecond; self.tokenSize = tokenSize
    }
}

private func estimateTokens(_ text: String) -> Int {
    Int((Double(text.utf16.count) / 4).rounded(.up))
}

/// `Math.random().toString(36).slice(2)`.
private func randomBase36() -> String {
    let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    let count = Int.random(in: 10...11)
    var out = ""
    for index in 0..<count {
        // The last digit of a JS random fraction is never 0.
        let range = index == count - 1 ? 1..<36 : 0..<36
        out.append(digits[Int.random(in: range)])
    }
    return out
}

private func randomId(_ prefix: String) -> String {
    "\(prefix):\(dateNow()):\(randomBase36())"
}

private func contentToText(_ content: UserMessageContent) -> String {
    switch content {
    case .string(let text): return text
    case .blocks(let blocks): return contentToText(blocks)
    }
}

private func contentToText(_ content: [UserContent]) -> String {
    content
        .map { block -> String in
            switch block {
            case .text(let text): return text.text
            case .image(let image): return "[image:\(image.mimeType):\(image.data.utf16.count)]"
            }
        }
        .joined(separator: "\n")
}

private func assistantContentToText(_ content: [AssistantContent]) -> String {
    content
        .map { block -> String in
            switch block {
            case .text(let text): return text.text
            case .thinking(let thinking): return thinking.thinking
            case .toolCall(let toolCall): return "\(toolCall.name):\(JsonValue.object(toolCall.arguments).serialized())"
            }
        }
        .joined(separator: "\n")
}

private func toolResultToText(_ message: ToolResultMessage) -> String {
    ([message.toolName] + message.content.map { contentToText([$0]) }).joined(separator: "\n")
}

private func messageToText(_ message: Message) -> String {
    switch message {
    case .system(let message):
        return ([getSystemMessageText(message)]
            + (message.toolsRemoved?.map { "tool-:\($0.json.serialized())" } ?? [])
            + (message.toolsAdded?.map { "tool+:\($0.json.serialized())" } ?? []))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    case .user(let message):
        return contentToText(message.content)
    case .assistant(let message):
        return assistantContentToText(message.content)
    case .toolResult(let message):
        return toolResultToText(message)
    }
}

/// Length of the prompt text that joins `messages` with blank lines.
private func joinedLength(_ messages: [String], _ count: Int? = nil) -> Int {
    let count = count ?? messages.count
    var length = count > 0 ? (count - 1) * 2 : 0
    for index in 0..<count { length += messages[index].utf16.count }
    return length
}

/// Length of the common prefix of the two joined prompts. Equal messages are compared whole; characters are compared
/// only from the first message that differs.
private func commonPromptPrefixLength(_ previous: [String], _ current: [String]) -> Int {
    var index = 0
    while index < previous.count && index < current.count && previous[index] == current[index] { index += 1 }
    let rest = { (messages: [String]) -> String in
        index == messages.count ? "" : (index > 0 ? "\n\n" : "") + messages[index...].joined(separator: "\n\n")
    }
    return joinedLength(previous, index) + commonPrefixLength(rest(previous), rest(current))
}

private func commonPrefixLength(_ a: String, _ b: String) -> Int {
    let a = Array(a.utf16), b = Array(b.utf16)
    let length = min(a.count, b.count)
    var index = 0
    while index < length && a[index] == b[index] {
        index += 1
    }
    return index
}

private func withUsageEstimate(
    _ message: AssistantMessage,
    _ context: TranscriptContext,
    _ options: StreamOptions?,
    _ promptCache: Locked<[String: [String]]>
) -> AssistantMessage {
    // One text per message; the whole prompt joins them with blank lines.
    let prompt = context.messages.map { "\($0.role):\(messageToText($0))" }
    let promptLength = joinedLength(prompt)
    let promptTokens = Int((Double(promptLength) / 4).rounded(.up))
    let outputTokens = estimateTokens(assistantContentToText(message.content))
    var input = promptTokens
    var cacheRead = 0
    var cacheWrite = 0
    let sessionId = options?.sessionId

    if let sessionId, !sessionId.isEmpty, options?.cacheRetention != CacheRetention.none {
        promptCache.withLock { cache in
            if let previousPrompt = cache[sessionId] {
                let cachedChars = commonPromptPrefixLength(previousPrompt, prompt)
                cacheRead = Int((Double(cachedChars) / 4).rounded(.up))
                cacheWrite = max(0, promptTokens - cacheRead)
            } else {
                cacheWrite = promptTokens
            }
            // Every prompt token is either read from or written to the simulated cache.
            input = 0
            cache[sessionId] = prompt
        }
    }

    var result = message
    result.usage = Usage(
        input: input,
        output: outputTokens,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        totalTokens: input + outputTokens + cacheRead + cacheWrite,
        cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
    )
    return result
}

/// Swift: chunk boundaries never split a UTF-16 surrogate pair (Swift strings cannot hold lone surrogates), so a chunk
/// may be one code unit longer than upstream's.
private func splitStringByTokenSize(_ text: String, _ minTokenSize: Int, _ maxTokenSize: Int) -> [String] {
    var chunks: [String] = []
    let units = Array(text.utf16)
    var index = 0
    while index < units.count {
        let tokenSize = minTokenSize + Int.random(in: 0..<(maxTokenSize - minTokenSize + 1))
        let charSize = max(1, tokenSize * 4)
        var end = min(units.count, index + charSize)
        if end < units.count && UTF16.isLeadSurrogate(units[end - 1]) { end += 1 }
        chunks.append(String(decoding: units[index..<end], as: UTF16.self))
        index = end
    }
    return chunks.isEmpty ? [""] : chunks
}

private func cloneMessage(_ message: AssistantMessage, _ api: String, _ provider: String, _ modelId: String) -> AssistantMessage {
    var cloned = message
    cloned.api = api
    cloned.provider = provider
    cloned.model = modelId
    return cloned
}

private func createDeferredMessage(_ model: Model, _ handle: DeferredHandle) -> AssistantMessage {
    var message = AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: DEFAULT_USAGE,
        stopReason: .deferred,
        timestamp: dateNow()
    )
    message.deferred = handle
    return message
}

private func createErrorMessage(_ error: any Error, _ api: String, _ provider: String, _ modelId: String) -> AssistantMessage {
    AssistantMessage(
        content: [],
        api: api,
        provider: provider,
        model: modelId,
        usage: DEFAULT_USAGE,
        stopReason: .error,
        errorMessage: errorMessage(error),
        timestamp: dateNow()
    )
}

private func createAbortedMessage(_ partial: AssistantMessage) -> AssistantMessage {
    var message = partial
    message.stopReason = .aborted
    message.errorMessage = "Request was aborted"
    message.timestamp = dateNow()
    return message
}

private func scheduleChunk(_ chunk: String, _ tokensPerSecond: Double?) async {
    guard let tokensPerSecond, tokensPerSecond > 0 else {
        await Task.yield()
        return
    }
    let delayMs = (Double(estimateTokens(chunk)) / tokensPerSecond) * 1000
    try? await Task.sleep(nanoseconds: UInt64(max(0, delayMs) * 1_000_000))
}

private func streamWithDeltas(
    _ stream: AssistantMessageEventStream,
    _ message: AssistantMessage,
    _ minTokenSize: Int,
    _ maxTokenSize: Int,
    _ tokensPerSecond: Double?,
    _ signal: AbortSignal?
) async throws {
    var partial = message
    partial.content = []
    partial.stopReason = .pending

    func abort() {
        let aborted = createAbortedMessage(partial)
        stream.push(.error(reason: .aborted, error: aborted))
        stream.end(aborted)
    }

    if signal?.aborted == true {
        abort()
        return
    }

    stream.push(.start(partial: partial))

    for (index, block) in message.content.enumerated() {
        if signal?.aborted == true {
            abort()
            return
        }

        switch block {
        case .thinking(let thinking):
            partial.content.append(.thinking(ThinkingContent(thinking: "")))
            stream.push(.thinkingStart(contentIndex: index, partial: partial))
            var accumulated = ""
            for chunk in splitStringByTokenSize(thinking.thinking, minTokenSize, maxTokenSize) {
                await scheduleChunk(chunk, tokensPerSecond)
                if signal?.aborted == true {
                    abort()
                    return
                }
                accumulated += chunk
                partial.content[index] = .thinking(ThinkingContent(thinking: accumulated))
                stream.push(.thinkingDelta(contentIndex: index, delta: chunk, partial: partial))
            }
            stream.push(.thinkingEnd(contentIndex: index, content: thinking.thinking, partial: partial))

        case .text(let text):
            partial.content.append(.text(TextContent(text: "")))
            stream.push(.textStart(contentIndex: index, partial: partial))
            var accumulated = ""
            for chunk in splitStringByTokenSize(text.text, minTokenSize, maxTokenSize) {
                await scheduleChunk(chunk, tokensPerSecond)
                if signal?.aborted == true {
                    abort()
                    return
                }
                accumulated += chunk
                partial.content[index] = .text(TextContent(text: accumulated))
                stream.push(.textDelta(contentIndex: index, delta: chunk, partial: partial))
            }
            stream.push(.textEnd(contentIndex: index, content: text.text, partial: partial))

        case .toolCall(let toolCall):
            partial.content.append(.toolCall(ToolCall(id: toolCall.id, name: toolCall.name, arguments: JsonObject())))
            stream.push(.toolcallStart(contentIndex: index, partial: partial))
            for chunk in splitStringByTokenSize(JsonValue.object(toolCall.arguments).serialized(), minTokenSize, maxTokenSize) {
                await scheduleChunk(chunk, tokensPerSecond)
                if signal?.aborted == true {
                    abort()
                    return
                }
                stream.push(.toolcallDelta(contentIndex: index, delta: chunk, partial: partial))
            }
            partial.content[index] = .toolCall(ToolCall(id: toolCall.id, name: toolCall.name, arguments: toolCall.arguments))
            stream.push(.toolcallEnd(contentIndex: index, toolCall: toolCall, partial: partial))
        }
    }

    if message.stopReason == .pending {
        throw PiError("Faux response ended without a stop reason")
    }
    if message.stopReason == .error || message.stopReason == .aborted {
        stream.push(.error(reason: message.stopReason, error: message))
        stream.end(message)
        return
    }

    stream.push(.done(reason: message.stopReason, message: message))
    stream.end(message)
}

/// JavaScript truthiness of `options.deferred`.
private func isTruthy(_ value: JsonValue?) -> Bool {
    switch value {
    case nil, .null?: return false
    case .bool(let v)?: return v
    case .number(let v)?: return v != 0 && !v.isNaN
    case .string(let v)?: return !v.isEmpty
    case .array?, .object?: return true
    }
}

private struct FauxDeferredEntry: Sendable {
    var handle: DeferredHandle
    var step: FauxResponseStep
    var context: TranscriptContext
    var options: SimpleStreamOptions?
    var model: Model
    var pendingFetches: Int
    var cancelled: Bool
    var final: AssistantMessage?
}

private struct FauxCoreState: Sendable {
    var pendingResponses: [FauxResponseStep] = []
    var state = FauxProviderState()
    var deferredResponses: [String: FauxDeferredEntry] = [:]
}

/// Result of `createFauxCore`.
public final class FauxCore: Sendable {
    public let api: String
    public let provider: String
    public let models: [Model]
    private let minTokenSize: Int
    private let maxTokenSize: Int
    private let tokensPerSecond: Double?
    private let deferredOptions: RegisterFauxProviderOptions.Deferred?
    private let shared = Locked(FauxCoreState())
    private let promptCache = Locked([String: [String]]())

    fileprivate init(_ options: RegisterFauxProviderOptions) {
        let api = options.api ?? randomId(DEFAULT_API)
        let provider = options.provider ?? DEFAULT_PROVIDER
        self.api = api
        self.provider = provider
        minTokenSize = max(1, min(options.tokenSize?.min ?? DEFAULT_MIN_TOKEN_SIZE, options.tokenSize?.max ?? DEFAULT_MAX_TOKEN_SIZE))
        maxTokenSize = max(minTokenSize, options.tokenSize?.max ?? DEFAULT_MAX_TOKEN_SIZE)
        tokensPerSecond = options.tokensPerSecond
        deferredOptions = options.deferred

        let modelDefinitions: [FauxModelDefinition] = (options.models?.isEmpty == false)
            ? options.models!
            : [
                FauxModelDefinition(
                    id: DEFAULT_MODEL_ID,
                    name: DEFAULT_MODEL_NAME,
                    reasoning: false,
                    input: ["text", "image"],
                    cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                    contextWindow: 128000,
                    maxTokens: 16384
                ),
            ]
        models = modelDefinitions.map { definition in
            var model = Model(
                id: definition.id,
                name: definition.name ?? definition.id,
                api: api,
                provider: provider,
                baseUrl: DEFAULT_BASE_URL,
                reasoning: definition.reasoning ?? false,
                input: definition.input ?? ["text", "image"],
                cost: definition.cost ?? ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                contextWindow: definition.contextWindow ?? 128000,
                maxTokens: definition.maxTokens ?? 16384
            )
            model.inputLimits = definition.inputLimits
            return model
        }
    }

    /// Snapshot of the provider state.
    public var state: FauxProviderState { shared.withLock { $0.state } }

    public func setResponses(_ responses: [FauxResponseStep]) {
        shared.withLock { $0.pendingResponses = responses }
    }

    public func appendResponses(_ responses: [FauxResponseStep]) {
        shared.withLock { $0.pendingResponses.append(contentsOf: responses) }
    }

    public func getPendingResponseCount() -> Int {
        shared.withLock { $0.pendingResponses.count }
    }

    public func getModel() -> Model {
        models[0]
    }

    public func getModel(_ requestedModelId: String?) -> Model? {
        guard let requestedModelId, !requestedModelId.isEmpty else { return models[0] }
        return models.first { $0.id == requestedModelId }
    }

    private func resolveResponse(
        _ step: FauxResponseStep,
        _ context: TranscriptContext,
        _ streamOptions: SimpleStreamOptions?,
        _ requestModel: Model
    ) async throws -> AssistantMessage {
        let resolved: AssistantMessage
        switch step {
        case .message(let message): resolved = message
        case .factory(let factory): resolved = try await factory(context, streamOptions, state, requestModel)
        }
        return withUsageEstimate(cloneMessage(resolved, api, provider, requestModel.id), context, streamOptions, promptCache)
    }

    public func stream(_ requestModel: Model, _ context: TranscriptContext, _ streamOptions: SimpleStreamOptions? = nil) -> AssistantMessageEventStream {
        let outer = createAssistantMessageEventStream()
        let step: FauxResponseStep? = shared.withLock { s in
            s.state.callCount += 1
            return s.pendingResponses.isEmpty ? nil : s.pendingResponses.removeFirst()
        }

        Task {
            do {
                try await streamOptions?.onResponse?(ProviderResponse(status: 200, headers: [:]), requestModel)
                guard let step else {
                    var message = createErrorMessage(PiError("No more faux responses queued"), api, provider, requestModel.id)
                    message = withUsageEstimate(message, context, streamOptions, promptCache)
                    outer.push(.error(reason: .error, error: message))
                    outer.end(message)
                    return
                }

                if let streamOptions, isTruthy(streamOptions.deferred) {
                    let handle = DeferredHandle(
                        provider: requestModel.provider,
                        modelId: requestModel.id,
                        api: requestModel.api,
                        id: randomId("deferred"),
                        pollAfterMs: deferredOptions?.pollAfterMs
                    )
                    let entry = FauxDeferredEntry(
                        handle: handle,
                        step: step,
                        context: context,
                        options: streamOptions,
                        model: requestModel,
                        pendingFetches: max(0, deferredOptions?.pendingFetches ?? 0),
                        cancelled: false
                    )
                    shared.withLock { $0.deferredResponses[handle.id] = entry }
                    try await streamWithDeltas(
                        outer,
                        createDeferredMessage(requestModel, handle),
                        minTokenSize,
                        maxTokenSize,
                        tokensPerSecond,
                        streamOptions.signal
                    )
                    return
                }

                let message = try await resolveResponse(step, context, streamOptions, requestModel)
                try await streamWithDeltas(outer, message, minTokenSize, maxTokenSize, tokensPerSecond, streamOptions?.signal)
            } catch {
                let message = createErrorMessage(error, api, provider, requestModel.id)
                outer.push(.error(reason: .error, error: message))
                outer.end(message)
            }
        }

        return outer
    }

    public func streamSimple(_ streamModel: Model, _ context: TranscriptContext, _ streamOptions: SimpleStreamOptions? = nil) -> AssistantMessageEventStream {
        stream(streamModel, context, streamOptions)
    }

    public func fetchDeferred(_ requestModel: Model, _ handle: DeferredHandle, _ fetchOptions: DeferredFetchOptions? = nil) -> AssistantMessageEventStream {
        let outer = createAssistantMessageEventStream()
        shared.withLock { $0.state.deferredFetchCount += 1 }

        Task {
            do {
                try await fetchOptions?.onResponse?(ProviderResponse(status: 200, headers: [:]), requestModel)
                guard let entry = shared.withLock({ $0.deferredResponses[handle.id] }),
                      entry.handle.provider == handle.provider,
                      entry.handle.modelId == handle.modelId,
                      entry.handle.api == handle.api
                else {
                    throw PiError("Unknown faux deferred response: \(handle.id)")
                }
                if entry.cancelled { throw PiError("Faux deferred response was cancelled: \(handle.id)") }

                if entry.pendingFetches > 0 {
                    shared.withLock { $0.deferredResponses[handle.id]?.pendingFetches -= 1 }
                    try await streamWithDeltas(
                        outer,
                        createDeferredMessage(requestModel, entry.handle),
                        minTokenSize,
                        maxTokenSize,
                        tokensPerSecond,
                        fetchOptions?.signal
                    )
                    return
                }

                var final = entry.final
                if final == nil {
                    var submissionOptions = entry.options ?? StreamOptions()
                    submissionOptions.deferred = nil
                    submissionOptions.signal = nil
                    submissionOptions.onResponse = nil
                    do {
                        final = try await resolveResponse(entry.step, entry.context, submissionOptions, entry.model)
                    } catch {
                        final = createErrorMessage(error, api, provider, entry.model.id)
                    }
                    shared.withLock { $0.deferredResponses[handle.id]?.final = final }
                }
                try await streamWithDeltas(outer, final!, minTokenSize, maxTokenSize, tokensPerSecond, fetchOptions?.signal)
            } catch {
                let message = createErrorMessage(error, api, provider, requestModel.id)
                outer.push(.error(reason: .error, error: message))
                outer.end(message)
            }
        }

        return outer
    }

    public func cancelDeferred(_ requestModel: Model, _ handle: DeferredHandle, _ cancelOptions: DeferredCancelOptions? = nil) async throws {
        shared.withLock { s in
            s.state.cancelledDeferred.append(handle)
            s.deferredResponses[handle.id]?.cancelled = true
        }
        try await cancelOptions?.onResponse?(ProviderResponse(status: 200, headers: [:]), requestModel)
    }

    /// `ProviderStreams` view of this core, for registries.
    public var streams: ProviderStreams {
        ProviderStreams(
            stream: { [self] model, context, options in stream(model, context, options) },
            streamSimple: { [self] model, context, options in streamSimple(model, context, options) }
        )
    }
}

public func createFauxCore(_ options: RegisterFauxProviderOptions = RegisterFauxProviderOptions()) -> FauxCore {
    FauxCore(options)
}

// Not ported: `fauxProvider` / `FauxProviderHandle` / `FauxProviderRegistration` — they wrap the core with
// `createProvider` from models.ts, which this group does not own.
