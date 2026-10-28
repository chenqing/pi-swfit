import Foundation

// Port of utils/diagnostics.ts

public struct DiagnosticErrorInfo: Sendable, Hashable {
    public var name: String?
    public var message: String
    public var stack: String?
    /// `string | number`
    public var code: JsonValue?
    public init(name: String? = nil, message: String, stack: String? = nil, code: JsonValue? = nil) {
        self.name = name; self.message = message; self.stack = stack; self.code = code
    }
}

public struct AssistantMessageDiagnostic: Sendable, Hashable {
    public var type: String
    public var timestamp: Int
    public var error: DiagnosticErrorInfo?
    public var details: JsonObject?
    public init(type: String, timestamp: Int = dateNow(), error: DiagnosticErrorInfo? = nil, details: JsonObject? = nil) {
        self.type = type; self.timestamp = timestamp; self.error = error; self.details = details
    }
}

public func formatThrownValue(_ value: any Error) -> String {
    errorMessage(value)
}

public func extractDiagnosticError(_ error: any Error) -> DiagnosticErrorInfo {
    let name: String? = (error as? PiError)?.name ?? (error is AbortError ? "AbortError" : "Error")
    let message = errorMessage(error)
    var code: JsonValue?
    if let coded = error as? any ErrorWithCode { code = coded.errorCode }
    return DiagnosticErrorInfo(name: name, message: message.isEmpty ? (name ?? "") : message, stack: nil, code: code)
}

/// Errors that carry a Node-style `code` (string or number).
public protocol ErrorWithCode: Error {
    var errorCode: JsonValue? { get }
}

public func createAssistantMessageDiagnostic(_ type: String, _ error: any Error, details: JsonObject? = nil) -> AssistantMessageDiagnostic {
    AssistantMessageDiagnostic(type: type, timestamp: dateNow(), error: extractDiagnosticError(error), details: details)
}

public func appendAssistantMessageDiagnostic(_ message: inout AssistantMessage, _ diagnostic: AssistantMessageDiagnostic) {
    message.diagnostics = (message.diagnostics ?? []) + [diagnostic]
}
