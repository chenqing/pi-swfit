import Foundation

// Port of packages/ai/src/providers/opencode-headers.ts

private let OPENCODE_SESSION_HEADER = "x-opencode-session"

private func hasHeader(_ headers: ProviderHeaders?, _ name: String) -> Bool {
    let expected = name.lowercased()
    return (headers ?? []).contains { $0.0.lowercased() == expected }
}

private func withSessionHeader(_ options: StreamOptions?) -> StreamOptions? {
    guard var options, let sessionId = options.sessionId, !sessionId.isEmpty, !hasHeader(options.headers, OPENCODE_SESSION_HEADER) else {
        return options
    }
    options.headers = (options.headers ?? []) + [(OPENCODE_SESSION_HEADER, sessionId)]
    return options
}

/// Adds OpenCode's required per-conversation routing header before API dispatch.
public func withOpenCodeSessionHeader(_ streams: ProviderStreams) -> ProviderStreams {
    var wrapped = streams
    wrapped.stream = { model, context, options in streams.stream(model, context, withSessionHeader(options)) }
    wrapped.streamSimple = { model, context, options in streams.streamSimple(model, context, withSessionHeader(options)) }
    return wrapped
}
