import Foundation
import PiAI
import PiCodingAgent

/// Native command outcomes; SDK error semantics and retention policy stay unchanged.
public enum CommandFeedback {
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? PiError else { return false }
        return ["Compaction cancelled", "Navigation cancelled", "Branch summarization cancelled", "This operation was aborted"].contains(error.message)
    }
    public static let cancelled = "Cancelled. No changes were made; your command is ready to edit."
    public static let nothingToCopy = "No assistant response to copy yet. Send a message first."
    public static func compact(_ session: AgentSession, instructions: String) async throws -> String {
        do {
            _ = try await session.compact(instructions.isEmpty ? nil : instructions)
            return "Context compacted. You can continue chatting."
        } catch {
            guard let failure = error as? PiError,
                  ["Nothing to compact (session too small)", "Already compacted"].contains(failure.message) else { throw error }
            if session.sessionManager.getBranch().last?.type == "compaction" {
                return "Context is already compacted. You can continue chatting."
            }
            let settings = try session.settingsManager.getCompactionSettings(await session.model)
            return "No compaction needed. The most recent \(settings.keepRecentTokens.formatted()) tokens are kept in full; there is no earlier context to summarize."
        }
    }
}
