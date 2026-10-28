import Foundation

// Port of packages/ai/src/api/azure-openai-config.ts
//
// Swift: `AzureEndpointOptions extends StreamOptions` adds `azureApiVersion`, `azureResourceName`,
// `azureBaseUrl` and `azureDeploymentName`; they are read from `StreamOptions.extra` under those names.

private let DEFAULT_AZURE_API_VERSION = "v1"

/// Azure models ship without a baseUrl: one resource per user, resolved per request.
public typealias AzureEndpointOptions = StreamOptions

extension StreamOptions {
    /// `options.azureApiVersion`, `options.azureResourceName`, ... (`undefined` for a missing or non-string value).
    fileprivate func azureOption(_ name: String) -> String? { extra[name]?.stringValue }
}

/// JS truthiness of an optional string.
private func truthy(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private func parseDeploymentNameMap(_ value: String?) -> [String: String] {
    var map: [String: String] = [:]
    guard let value = truthy(value) else { return map }
    for entry in value.components(separatedBy: ",") {
        let trimmed = jsTrim(entry)
        if trimmed.isEmpty { continue }
        // `trimmed.split("=", 2)`: the first two pieces; anything after a second "=" is dropped.
        let pieces = trimmed.components(separatedBy: "=")
        let modelId = pieces[0]
        let deploymentName = pieces.count > 1 ? pieces[1] : nil
        guard !modelId.isEmpty, let deploymentName, !deploymentName.isEmpty else { continue }
        map[jsTrim(modelId)] = jsTrim(deploymentName)
    }
    return map
}

public func resolveDeploymentName(_ model: Model, _ options: AzureEndpointOptions? = nil) -> String {
    if let azureDeploymentName = truthy(options?.azureOption("azureDeploymentName")) {
        return azureDeploymentName
    }
    let mappedDeployment = parseDeploymentNameMap(
        getProviderEnvValue("AZURE_OPENAI_DEPLOYMENT_NAME_MAP", options?.env)
    )[model.id]
    return truthy(mappedDeployment) ?? model.id
}

private func normalizeAzureBaseUrl(_ baseUrl: String) throws -> String {
    var trimmed = jsTrim(baseUrl)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard var url = WebURL(trimmed) else {
        throw PiError("Invalid Azure OpenAI base URL: \(baseUrl)")
    }

    let isAzureHost =
        url.hostname.hasSuffix(".openai.azure.com") ||
        url.hostname.hasSuffix(".cognitiveservices.azure.com") ||
        url.hostname.hasSuffix(".ai.azure.com")
    var normalizedPath = url.pathname
    while normalizedPath.hasSuffix("/") { normalizedPath.removeLast() }

    // Ensure Azure hosts have /openai/v1 as base path so the AzureOpenAI SDK
    // can append /deployments/<model>/... and ?api-version=v1 correctly.
    if isAzureHost &&
        (normalizedPath == "" ||
            normalizedPath == "/" ||
            normalizedPath == "/openai" ||
            normalizedPath == "/openai/v1/responses")
    {
        url = url.withPathname("/openai/v1").withSearch(URLSearchParams(""))
    }

    var result = url.href
    while result.hasSuffix("/") { result.removeLast() }
    return result
}

private func buildDefaultBaseUrl(_ resourceName: String) -> String {
    "https://\(resourceName).openai.azure.com/openai/v1"
}

public func resolveAzureBaseUrl(_ model: Model, _ options: AzureEndpointOptions? = nil) throws -> String {
    let baseUrl =
        truthy(options?.azureOption("azureBaseUrl").map(jsTrim)) ??
        truthy(getProviderEnvValue("AZURE_OPENAI_BASE_URL", options?.env).map(jsTrim)) ??
        nil
    let resourceName = truthy(options?.azureOption("azureResourceName")) ?? getProviderEnvValue("AZURE_OPENAI_RESOURCE_NAME", options?.env)

    var resolvedBaseUrl = baseUrl

    if resolvedBaseUrl == nil, let resourceName = truthy(resourceName) {
        resolvedBaseUrl = buildDefaultBaseUrl(resourceName)
    }

    if resolvedBaseUrl == nil, let modelBaseUrl = truthy(model.baseUrl) {
        resolvedBaseUrl = modelBaseUrl
    }

    guard let resolvedBaseUrl else {
        throw PiError(
            "Azure OpenAI base URL is required. Set AZURE_OPENAI_BASE_URL or AZURE_OPENAI_RESOURCE_NAME, or pass azureBaseUrl, azureResourceName, or model.baseUrl."
        )
    }

    return try normalizeAzureBaseUrl(resolvedBaseUrl)
}

public func resolveAzureConfig(_ model: Model, _ options: AzureEndpointOptions? = nil) throws -> (baseUrl: String, apiVersion: String) {
    return (
        baseUrl: try resolveAzureBaseUrl(model, options),
        apiVersion:
            truthy(options?.azureOption("azureApiVersion")) ??
            truthy(getProviderEnvValue("AZURE_OPENAI_API_VERSION", options?.env)) ??
            DEFAULT_AZURE_API_VERSION
    )
}
