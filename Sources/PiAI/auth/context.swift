import Foundation

// Port of packages/ai/src/auth/context.ts

/// Default auth context: env vars from the process environment,
/// file existence via FileManager.
public func defaultProviderAuthContext() -> AuthContext {
    AuthContext(
        env: { name in
            let value = getenv(name).map { String(cString: $0) }
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            return nil
        },
        fileExists: { path in
            var resolved = path
            if resolved.hasPrefix("~") {
                resolved = FileManager.default.homeDirectoryForCurrentUser.path + String(resolved.dropFirst())
            }
            return FileManager.default.fileExists(atPath: resolved)
        }
    )
}
