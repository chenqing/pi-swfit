import Foundation

// Port of packages/ai/src/providers/cloudflare-stream.ts

private let CLOUDFLARE_ACCOUNT_ID = "CLOUDFLARE_ACCOUNT_ID"
private let CLOUDFLARE_GATEWAY_ID = "CLOUDFLARE_GATEWAY_ID"

public func resolveCloudflareModel(_ model: Model, _ env: ProviderEnv?) -> Model {
    guard let env else { return model }
    let baseUrl = model.baseUrl
        .replacingOccurrences(of: "{\(CLOUDFLARE_ACCOUNT_ID)}", with: env[CLOUDFLARE_ACCOUNT_ID] ?? "{\(CLOUDFLARE_ACCOUNT_ID)}")
        .replacingOccurrences(of: "{\(CLOUDFLARE_GATEWAY_ID)}", with: env[CLOUDFLARE_GATEWAY_ID] ?? "{\(CLOUDFLARE_GATEWAY_ID)}")
    if baseUrl == model.baseUrl { return model }
    var resolved = model
    resolved.baseUrl = baseUrl
    return resolved
}

/// Wrap an API implementation so Cloudflare account/gateway endpoint
/// placeholders materialize from the resolved provider env before dispatch.
/// (Like upstream, the wrapper exposes only `stream`/`streamSimple`.)
public func cloudflareStreams(_ streams: ProviderStreams) -> ProviderStreams {
    ProviderStreams(
        stream: { model, context, options in streams.stream(resolveCloudflareModel(model, options?.env), context, options) },
        streamSimple: { model, context, options in streams.streamSimple(resolveCloudflareModel(model, options?.env), context, options) }
    )
}

// Not ported: cloudflareClassifier (classifier APIs are out of scope).
