import Foundation

/// Provider-reported usage for the visible conversation branch, not a context-capacity estimate.
public struct ChatUsageSummary: Sendable, Equatable {
    public let reportedRequests: Int
    public let lastInput: Int?
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int

    public init(messages: [ChatMessage]) {
        let usage = messages.filter { $0.role == .assistant }.compactMap(\.usage)
        reportedRequests = usage.count
        lastInput = usage.last.map { $0.input + $0.cacheRead + $0.cacheWrite }
        input = usage.reduce(0) { $0 + $1.input + $1.cacheRead + $1.cacheWrite }
        output = usage.reduce(0) { $0 + $1.output }
        cacheRead = usage.reduce(0) { $0 + $1.cacheRead }
        cacheWrite = usage.reduce(0) { $0 + $1.cacheWrite }
    }
}
