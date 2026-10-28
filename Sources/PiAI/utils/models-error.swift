import Foundation

// Port of utils/models-error.ts

/// `"model_source" | "model_validation" | "provider" | "stream" | "auth" | "oauth"`
public enum ModelsErrorCode: String, Sendable, Hashable {
    case model_source, model_validation, provider, stream, auth, oauth
}

public struct ModelsError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public let code: ModelsErrorCode
    public let message: String
    public let name = "ModelsError"
    public let cause: (any Error)?

    public init(_ code: ModelsErrorCode, _ message: String, cause: (any Error)? = nil) {
        self.message = withCauseDetail(message, cause)
        self.code = code
        self.cause = cause
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Callers surface `error.message` only, so keep the underlying reason in it.
private func withCauseDetail(_ message: String, _ cause: (any Error)?) -> String {
    guard let cause else { return message }
    let detail = formatThrownValue(cause).trimmingCharacters(in: .whitespacesAndNewlines)
    if detail.isEmpty || message.contains(detail) { return message }
    return "\(message): \(detail)"
}
