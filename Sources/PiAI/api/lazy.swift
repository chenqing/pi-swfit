import Foundation

// Port of packages/ai/src/api/lazy.ts

private func createSetupErrorMessage(_ model: Model, _ error: any Error, _ timestamp: Int) -> AssistantMessage {
    AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)),
        stopReason: .error,
        errorMessage: errorMessage(error),
        timestamp: timestamp
    )
}

// hasResult(): every Swift source is an `AssistantMessageEventStream`, which always has `result()`.

/// Synchronous, read-only observation of the stream's existing forwarding path.
public struct LazyStreamObserver: Sendable {
    public var onEvent: (@Sendable (AssistantMessageEvent) -> Void)?
    public var onResult: (@Sendable (AssistantMessage?) -> Void)?
    public init(onEvent: (@Sendable (AssistantMessageEvent) -> Void)? = nil, onResult: (@Sendable (AssistantMessage?) -> Void)? = nil) {
        self.onEvent = onEvent; self.onResult = onResult
    }
}

private func forwardStream(
    _ target: AssistantMessageEventStream,
    _ source: AssistantMessageEventStream,
    _ observer: LazyStreamObserver?,
    _ observeResult: @Sendable (AssistantMessage?) -> Void
) async {
    var result: AssistantMessage?
    for await event in source {
        target.push(event)
        observer?.onEvent?(event)
        if case .done(_, let message) = event { result = message }
        else if case .error(_, let error) = event { result = error }
    }
    // `source.result()`; a source that ended without a result resolves undefined.
    result = await source.resultIfAny()
    target.end(result)
    observeResult(result)
}

/// Returns a stream synchronously while running async setup (auth resolution,
/// lazy module loading) behind it. Setup failures terminate the stream with an
/// error event.
public func lazyStream(
    _ model: Model,
    _ setup: @escaping @Sendable () async throws -> AssistantMessageEventStream,
    _ observer: LazyStreamObserver? = nil
) -> AssistantMessageEventStream {
    let startedAt = dateNow()
    let outer = AssistantMessageEventStream()
    let observedResult = Locked(false)
    let observeResult: @Sendable (AssistantMessage?) -> Void = { result in
        let first = observedResult.withLock { observed -> Bool in
            if observed { return false }
            observed = true
            return true
        }
        if !first { return }
        observer?.onResult?(result)
    }

    Task {
        let inner: AssistantMessageEventStream
        do {
            inner = try await setup()
        } catch {
            let message = createSetupErrorMessage(model, error, startedAt)
            let event = AssistantMessageEvent.error(reason: .error, error: message)
            outer.push(event)
            observer?.onEvent?(event)
            outer.end(message)
            observeResult(message)
            return
        }
        await forwardStream(outer, inner, observer, observeResult)
    }

    return outer
}

/// Wraps a dynamically imported API implementation module as `ProviderStreams`.
/// The module loads on first stream call; the host's import cache deduplicates
/// loads. Load failures terminate the returned stream with an error event.
public struct LazyApiCapabilities: Sendable {
    public var fetchDeferred: Bool?
    public var cancelDeferred: Bool?
    public init(fetchDeferred: Bool? = nil, cancelDeferred: Bool? = nil) { self.fetchDeferred = fetchDeferred; self.cancelDeferred = cancelDeferred }
}

public func lazyApi(_ load: @escaping @Sendable () async throws -> ProviderStreams, _ capabilities: LazyApiCapabilities? = nil) -> ProviderStreams {
    var api = ProviderStreams(
        stream: { model, context, options in
            lazyStream(model, { try await load().stream(model, context, options) })
        },
        streamSimple: { model, context, options in
            lazyStream(model, { try await load().streamSimple(model, context, options) })
        }
    )

    if capabilities?.fetchDeferred == true {
        api.fetchDeferred = { model, handle, options in
            lazyStream(model, {
                let implementation = try await load()
                guard let fetchDeferred = implementation.fetchDeferred else { throw PiError("API does not support deferred responses") }
                return fetchDeferred(model, handle, options)
            })
        }
    }
    if capabilities?.cancelDeferred == true {
        api.cancelDeferred = { model, handle, options in
            let implementation = try await load()
            guard let cancelDeferred = implementation.cancelDeferred else { throw PiError("API cannot cancel deferred responses") }
            try await cancelDeferred(model, handle, options)
        }
    }

    return api
}
