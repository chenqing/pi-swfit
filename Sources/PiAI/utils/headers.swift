import Foundation

// Port of utils/headers.ts

public func headersToRecord(_ headers: Headers) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in headers.record {
        result[key] = value
    }
    return result
}

/// Merges header sources case-insensitively. Later sources win; a nil value removes the header.
/// Swift: returns the merged headers as an ordered list (upstream `Object.fromEntries` keeps insertion order).
public func providerHeadersToRecord(_ headerSources: ProviderHeaders?...) -> [(String, String)]? {
    providerHeadersToRecord(headerSources)
}

public func providerHeadersToRecord(_ headerSources: [ProviderHeaders?]) -> [(String, String)]? {
    var merged: [(normalized: String, name: String, value: String)] = []
    for source in headerSources {
        for (name, value) in source ?? [] {
            let normalizedName = name.lowercased()
            merged.removeAll { $0.normalized == normalizedName }
            if let value { merged.append((normalizedName, name, value)) }
        }
    }
    return merged.count > 0 ? merged.map { ($0.name, $0.value) } : nil
}
