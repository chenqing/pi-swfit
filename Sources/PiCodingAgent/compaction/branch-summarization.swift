/**
 * Branch summarization for tree navigation.
 *
 * When navigating to a different point in the session tree, this generates
 * a summary of the branch being left so context isn't lost.
 */

import Foundation
import PiAI
import PiAgent

// Port of packages/coding-agent/src/core/compaction/branch-summarization.ts

// ============================================================================
// Types
// ============================================================================

public struct BranchSummaryResult: Sendable {
    public var summary: String?
    public var usage: Usage?
    public var readFiles: [String]?
    public var modifiedFiles: [String]?
    public var aborted: Bool?
    public var error: String?
    public init(summary: String? = nil, usage: Usage? = nil, readFiles: [String]? = nil, modifiedFiles: [String]? = nil, aborted: Bool? = nil, error: String? = nil) {
        self.summary = summary; self.usage = usage; self.readFiles = readFiles; self.modifiedFiles = modifiedFiles; self.aborted = aborted; self.error = error
    }
}

/** Details stored in BranchSummaryEntry.details for file tracking */
public struct BranchSummaryDetails: Sendable, Hashable {
    public var readFiles: [String]
    public var modifiedFiles: [String]
    public init(readFiles: [String], modifiedFiles: [String]) { self.readFiles = readFiles; self.modifiedFiles = modifiedFiles }

    public var json: JsonValue {
        ["readFiles": .array(readFiles.map(JsonValue.string)), "modifiedFiles": .array(modifiedFiles.map(JsonValue.string))]
    }
}

public struct BranchPreparation: Sendable {
    /** Messages extracted for summarization, in chronological order */
    public var messages: [AgentMessage]
    /** File operations extracted from tool calls */
    public var fileOps: FileOperations
    /** Total estimated tokens in messages */
    public var totalTokens: Int
    public init(messages: [AgentMessage], fileOps: FileOperations, totalTokens: Int) {
        self.messages = messages; self.fileOps = fileOps; self.totalTokens = totalTokens
    }
}

public struct CollectEntriesResult: Sendable {
    /** Entries to summarize, in chronological order */
    public var entries: [SessionEntry]
    /** Common ancestor between old and new position, if any */
    public var commonAncestorId: String?
    public init(entries: [SessionEntry], commonAncestorId: String?) { self.entries = entries; self.commonAncestorId = commonAncestorId }
}

public struct GenerateBranchSummaryOptions: Sendable {
    /** Model to use for summarization */
    public var model: Model
    /** API key for the model */
    public var apiKey: String?
    /** Request headers for the model */
    public var headers: ProviderHeaders?
    /** Provider-scoped environment values for the model */
    public var env: ProviderEnv?
    /** Abort signal for cancellation */
    public var signal: AbortSignal
    /** Optional custom instructions for summarization */
    public var customInstructions: String?
    /** If true, customInstructions replaces the default prompt instead of being appended */
    public var replaceInstructions: Bool?
    /** Tokens reserved when selecting branch history (default 16384) */
    public var reserveTokens: Int?
    /** Optional session stream function. Used to preserve SDK request behavior without mutating agent state. */
    public var streamFn: StreamFn?
    /** Retry policy for transient summarization errors. Reuses coding-agent's `settings.retry`. */
    public var retry: RetryPolicy?
    /** Optional callbacks for retry reporting (e.g. TUI retry indicators). */
    public var callbacks: RetryCallbacks?
    public init(model: Model, apiKey: String? = nil, headers: ProviderHeaders? = nil, env: ProviderEnv? = nil, signal: AbortSignal, customInstructions: String? = nil, replaceInstructions: Bool? = nil, reserveTokens: Int? = nil, streamFn: StreamFn? = nil, retry: RetryPolicy? = nil, callbacks: RetryCallbacks? = nil) {
        self.model = model; self.apiKey = apiKey; self.headers = headers; self.env = env; self.signal = signal
        self.customInstructions = customInstructions; self.replaceInstructions = replaceInstructions; self.reserveTokens = reserveTokens
        self.streamFn = streamFn; self.retry = retry; self.callbacks = callbacks
    }
}

// ============================================================================
// Entry Collection
// ============================================================================

/**
 * Collect entries that should be summarized when navigating from one position to another.
 *
 * Walks from oldLeafId back to the common ancestor with targetId, collecting entries
 * along the way. Does NOT stop at compaction boundaries - those are included and their
 * summaries become context.
 *
 * @param session - Session manager (read-only access)
 * @param oldLeafId - Current position (where we're navigating from)
 * @param targetId - Target position (where we're navigating to)
 * @returns Entries to summarize and the common ancestor
 */
public func collectEntriesForBranchSummary(
    _ session: ReadonlySessionManager,
    _ oldLeafId: String?,
    _ targetId: String
) -> CollectEntriesResult {
    // If no old position, nothing to summarize
    guard let oldLeafId, !oldLeafId.isEmpty else {
        return CollectEntriesResult(entries: [], commonAncestorId: nil)
    }

    // Find common ancestor (deepest node that's on both paths)
    let oldPath = Set(session.getBranch(oldLeafId).map(\.id))
    let targetPath = session.getBranch(targetId)

    // targetPath is root-first, so iterate backwards to find deepest common ancestor
    var commonAncestorId: String?
    for entry in targetPath.reversed() {
        if oldPath.contains(entry.id) {
            commonAncestorId = entry.id
            break
        }
    }

    // Collect entries from old leaf back to common ancestor
    var entries: [SessionEntry] = []
    var current: String? = oldLeafId

    while let id = current, !id.isEmpty, id != commonAncestorId {
        guard let entry = session.getEntry(id) else { break }
        entries.append(entry)
        current = entry.parentId
    }

    // Reverse to get chronological order
    entries.reverse()

    return CollectEntriesResult(entries: entries, commonAncestorId: commonAncestorId)
}

// ============================================================================
// Entry to Message Conversion
// ============================================================================

/**
 * Extract AgentMessage from a session entry.
 * Similar to getMessageFromEntry in compaction.ts but also handles compaction entries.
 */
private func getMessageFromEntry(_ entry: SessionEntry) -> AgentMessage? {
    switch entry {
    case .message(let e):
        // Skip tool results - context is in assistant's tool call
        if e.message.role == "toolResult" { return nil }
        return e.message

    case .customMessage(let e):
        // Swift: missing content (unvalidated files) becomes an empty block list.
        return createCustomMessage(e.customType, e.content ?? .blocks([]), e.display, e.details, e.timestamp).agentMessage

    case .branchSummary(let e):
        return createBranchSummaryMessage(e.summary, e.fromId, e.timestamp).agentMessage

    case .compaction(let e):
        return createCompactionSummaryMessage(e.summary, e.tokensBefore, e.timestamp).agentMessage

    // These don't contribute to conversation content
    default:
        return nil
    }
}

/**
 * Prepare entries for summarization with token budget.
 *
 * Walks entries from NEWEST to OLDEST, adding messages until we hit the token budget.
 * This ensures we keep the most recent context when the branch is too long.
 *
 * Also collects file operations from:
 * - Tool calls in assistant messages
 * - Existing branch_summary entries' details (for cumulative tracking)
 *
 * @param entries - Entries in chronological order
 * @param tokenBudget - Maximum tokens to include (0 = no limit)
 */
public func prepareBranchEntries(_ entries: [SessionEntry], _ tokenBudget: Int = 0) -> BranchPreparation {
    var messages: [AgentMessage] = []
    var fileOps = createFileOps()
    var totalTokens = 0

    // First pass: collect file ops from ALL entries (even if they don't fit in token budget)
    // This ensures we capture cumulative file tracking from nested branch summaries
    // Only extract from pi-generated summaries (fromHook !== true), not extension-generated ones
    for entry in entries {
        if case .branchSummary(let e) = entry, e.fromHook != true, let details = e.details, !details.isNull {
            if let readFiles = details["readFiles"]?.arrayValue {
                for f in readFiles { if let f = f.stringValue { fileOps.read.insert(f) } }
            }
            if let modifiedFiles = details["modifiedFiles"]?.arrayValue {
                // Modified files go into both edited and written for proper deduplication
                for f in modifiedFiles {
                    if let f = f.stringValue { fileOps.edited.insert(f) }
                }
            }
        }
    }

    // Second pass: walk from newest to oldest, adding messages until token budget
    for entry in entries.reversed() {
        guard let message = getMessageFromEntry(entry) else { continue }

        // Extract file ops from assistant messages (tool calls)
        extractFileOpsFromMessage(message, &fileOps)

        let tokens = estimateTokens(message)

        // Check budget before adding
        if tokenBudget > 0 && totalTokens + tokens > tokenBudget {
            // If this is a summary entry, try to fit it anyway as it's important context
            if entry.type == "compaction" || entry.type == "branch_summary" {
                if Double(totalTokens) < Double(tokenBudget) * 0.9 {
                    messages.insert(message, at: 0)
                    totalTokens += tokens
                }
            }
            // Stop - we've hit the budget
            break
        }

        messages.insert(message, at: 0)
        totalTokens += tokens
    }

    return BranchPreparation(messages: messages, fileOps: fileOps, totalTokens: totalTokens)
}

// ============================================================================
// Summary Generation
// ============================================================================

private let BRANCH_SUMMARY_PREAMBLE = """
The user explored a different conversation branch before returning here.
Summary of that exploration:


"""

private let BRANCH_SUMMARY_PROMPT = """
Create a structured summary of this conversation branch for context when returning later.

Use this EXACT format:

## Goal
[What was the user trying to accomplish in this branch?]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Work that was started but not finished]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [What should happen next to continue this work]

Keep each section concise. Preserve exact file paths, function names, and error messages.
"""

/**
 * Generate a summary of abandoned branch entries.
 *
 * @param entries - Session entries to summarize (chronological order)
 * @param options - Generation options
 */
public func generateBranchSummary(
    _ entries: [SessionEntry],
    _ options: GenerateBranchSummaryOptions
) async throws -> BranchSummaryResult {
    let model = options.model
    let reserveTokens = options.reserveTokens ?? 16384

    // Token budget = context window minus reserved space for prompt + response
    let contextWindow = model.contextWindow != 0 ? model.contextWindow : 128000
    let tokenBudget = contextWindow - reserveTokens

    let preparation = prepareBranchEntries(entries, tokenBudget)
    let messages = preparation.messages
    let fileOps = preparation.fileOps

    if messages.isEmpty {
        return BranchSummaryResult(summary: "No content to summarize")
    }

    // Transform to LLM-compatible messages, then serialize to text
    // Serialization prevents the model from treating it as a conversation to continue
    let llmMessages = convertToLlm(messages)
    let conversationText = serializeConversation(llmMessages)

    // Build prompt
    let instructions: String
    if options.replaceInstructions == true, let customInstructions = options.customInstructions, !customInstructions.isEmpty {
        instructions = customInstructions
    } else if let customInstructions = options.customInstructions, !customInstructions.isEmpty {
        instructions = "\(BRANCH_SUMMARY_PROMPT)\n\nAdditional focus: \(customInstructions)"
    } else {
        instructions = BRANCH_SUMMARY_PROMPT
    }
    let promptText = "<conversation>\n\(conversationText)\n</conversation>\n\n\(instructions)"

    let summarizationMessages: [Message] = [
        .user(UserMessage(
            content: .blocks([.text(TextContent(text: promptText))]),
            timestamp: dateNow()
        )),
    ]

    // Call LLM for summarization. Prefer the session stream function so SDK
    // request behavior (timeouts, retries, attribution headers) stays consistent
    // without running through agent state/events. Retried via completeSummarization
    // so transient stream drops reuse the configured retry policy.
    let context = normalizeContext(Context(systemPrompt: SUMMARIZATION_SYSTEM_PROMPT, messages: summarizationMessages))
    var requestOptions = SimpleStreamOptions()
    requestOptions.apiKey = options.apiKey
    requestOptions.headers = options.headers
    requestOptions.env = options.env
    requestOptions.signal = options.signal
    let response = try await completeSummarization(model, context, requestOptions, options.streamFn, options.retry, options.callbacks)

    // Check if aborted or errored
    if response.stopReason == .aborted {
        return BranchSummaryResult(aborted: true)
    }
    if let failure = getSummarizationFailure(response, "Branch summarization") {
        return BranchSummaryResult(error: failure)
    }
    if response.content.contains(where: { $0.type == "toolCall" }) {
        return BranchSummaryResult(error: "Branch summarization attempted to call a tool")
    }

    var summary = contentText(response.content)

    // Prepend preamble to provide context about the branch summary
    summary = BRANCH_SUMMARY_PREAMBLE + summary

    // Compute file lists and append to summary
    let (readFiles, modifiedFiles) = computeFileLists(fileOps)
    summary += formatFileOperations(readFiles, modifiedFiles)

    return BranchSummaryResult(
        summary: summary.isEmpty ? "No summary generated" : summary,
        usage: response.usage,
        readFiles: readFiles,
        modifiedFiles: modifiedFiles
    )
}
