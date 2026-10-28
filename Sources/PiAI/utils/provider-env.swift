import Foundation

// Port of utils/provider-env.ts

// Not ported: getBunSandboxEnvValue (Bun-only /proc/self/environ fallback).

/// Resolve a provider env value from scoped overrides, then the normal process environment.
public func getProviderEnvValue(_ name: String, _ env: ProviderEnv? = nil) -> String? {
    if let value = env?[name], !value.isEmpty { return value }
    if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
    return nil
}
