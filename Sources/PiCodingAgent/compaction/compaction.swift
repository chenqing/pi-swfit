/**
 * Context compaction for long sessions.
 *
 * Pure functions for compaction logic. The session manager handles I/O,
 * and after compaction the session is reloaded.
 */

import Foundation
import PiAI
import PiAgent

// Port of packages/coding-agent/src/core/compaction/compaction.ts

// ============================================================================
// File Operation Tracking
// ============================================================================

/** Details stored in CompactionEntry.details for file tracking */
public struct CompactionDetails: Sendable, Hashable {
    public var readFiles: [String]
    public var modifiedFiles: [String]
    public init(readFiles: [String], modifiedFiles: [String]) { self.readFiles = readFiles; self.modifiedFiles = modifiedFiles }

    public var json: JsonValue {
        ["readFiles": .array(readFiles.map(JsonValue.string)), "modifiedFiles": .array(modifiedFiles.map(JsonValue.string))]
    }
}

/**
 * Extract file operations from messages and previous compaction entries.
 */
private func extractFileOperations(
    _ messages: [AgentMessage],
    _ entries: [SessionEntry],
    _ prevCompactionIndex: Int
) -> FileOperations {
    var fileOps = createFileOps()

    // Collect from previous compaction's details (if pi-generated)
    if prevCompactionIndex >= 0, case .compaction(let prevCompaction) = entries[prevCompactionIndex] {
        if prevCompaction.fromHook != true, let details = prevCompaction.details, !details.isNull {
            // fromHook field kept for session file compatibility
            if let readFiles = details["readFiles"]?.arrayValue {
                for f in readFiles { if let f = f.stringValue { fileOps.read.insert(f) } }
            }
            if let modifiedFiles = details["modifiedFiles"]?.arrayValue {
                for f in modifiedFiles { if let f = f.stringValue { fileOps.edited.insert(f) } }
            }
        }
    }

    // Extract from tool calls in messages
    for msg in messages {
        extractFileOpsFromMessage(msg, &fileOps)
    }

    return fileOps
}

// ============================================================================
// Message Extraction
// ============================================================================

/**
 * Extract AgentMessage from an entry if it produces one.
 * Returns undefined for entries that don't contribute to LLM context.
 */
private func getMessagesFromProjectedEntryForCompaction(_ entry: ProjectedSessionEntry) -> [AgentMessage] {
    if case .compaction = entry.sourceEntry { return [] }
    // System messages are prompt state, not conversation; the compaction entry carries their replay.
    return entry.messages.filter { $0.role != "system" }
}

/** Result from compact() - SessionManager adds uuid/parentUuid when saving */
public struct CompactionResult: Sendable {
    public var summary: String
    public var firstKeptEntryId: String?
    public var tokensBefore: Int
    public var estimatedTokensAfter: Int?
    /** Usage from the LLM call(s) that generated this summary, if available */
    public var usage: Usage?
    /** Extension-specific data (e.g., ArtifactIndex, version markers for structured compaction) */
    public var details: JsonValue?
    public init(summary: String, firstKeptEntryId: String?, tokensBefore: Int, estimatedTokensAfter: Int? = nil, usage: Usage? = nil, details: JsonValue? = nil) {
        self.summary = summary; self.firstKeptEntryId = firstKeptEntryId; self.tokensBefore = tokensBefore
        self.estimatedTokensAfter = estimatedTokensAfter; self.usage = usage; self.details = details
    }
}

// ============================================================================
// Types
// ============================================================================

public struct CompactionSettings: Sendable, Hashable {
    public var enabled: Bool
    public var reserveTokens: Int
    public var keepRecentTokens: Int
    public init(enabled: Bool, reserveTokens: Int, keepRecentTokens: Int) {
        self.enabled = enabled; self.reserveTokens = reserveTokens; self.keepRecentTokens = keepRecentTokens
    }
}

public let DEFAULT_COMPACTION_SETTINGS = CompactionSettings(
    enabled: true,
    reserveTokens: 16384,
    keepRecentTokens: 20000
)

// ============================================================================
// Token calculation
// ============================================================================

/**
 * Calculate total context tokens from usage.
 * Uses the native totalTokens field when available, falls back to computing from components.
 */
// Swift: `calculateContextTokens(_ usage: Usage)` is PiAI's identical function (same body); not redeclared.

/**
 * Get usage from an assistant message if available.
 * Skips aborted, error, and all-zero usage messages as they don't have valid usage data.
 */
private func getAssistantUsage(_ msg: AgentMessage) -> Usage? {
    if case .assistant(let assistantMsg) = msg {
        if assistantMsg.stopReason != .aborted &&
            assistantMsg.stopReason != .error &&
            calculateContextTokens(assistantMsg.usage) > 0
        {
            return assistantMsg.usage
        }
    }
    return nil
}

/**
 * Find the last valid assistant message usage from session entries.
 */
public func getLastAssistantUsage(_ entries: [SessionEntry]) -> Usage? {
    for entry in entries.reversed() {
        if case .message(let e) = entry {
            if let usage = getAssistantUsage(e.message) { return usage }
        }
    }
    return nil
}

// Swift: `ContextUsageEstimate` is PiAI's identical struct (tokens, usageTokens, trailingTokens, lastUsageIndex).

private func getLastAssistantUsageInfo(_ messages: [AgentMessage]) -> (usage: Usage, index: Int)? {
    for i in stride(from: messages.count - 1, through: 0, by: -1) {
        if let usage = getAssistantUsage(messages[i]) { return (usage, i) }
    }
    return nil
}

/**
 * Estimate context tokens from messages, using the last assistant usage when available.
 * If there are messages after the last usage, estimate their tokens with estimateTokens.
 */
public func estimateContextTokens(_ messages: [AgentMessage]) -> ContextUsageEstimate {
    guard let usageInfo = getLastAssistantUsageInfo(messages) else {
        var estimated = 0
        for message in messages {
            estimated += estimateTokens(message)
        }
        return ContextUsageEstimate(
            tokens: estimated,
            usageTokens: 0,
            trailingTokens: estimated,
            lastUsageIndex: nil
        )
    }

    let usageTokens = calculateContextTokens(usageInfo.usage)
    var trailingTokens = 0
    for i in (usageInfo.index + 1)..<max(usageInfo.index + 1, messages.count) {
        trailingTokens += estimateTokens(messages[i])
    }

    return ContextUsageEstimate(
        tokens: usageTokens + trailingTokens,
        usageTokens: usageTokens,
        trailingTokens: trailingTokens,
        lastUsageIndex: usageInfo.index
    )
}

/** Estimate projected context without trusting usage captured before a later edit or compaction. */
public func estimateProjectedContextTokens(
    _ projection: SessionProjection,
    _ branchEntries: [SessionEntry]
) -> ContextUsageEstimate {
    let estimate = estimateContextTokens(projection.messages)
    if let lastUsageIndex = estimate.lastUsageIndex {
        var projectedMessageIndex = 0
        var usageEntryId: String?
        for entry in projection.entries {
            let nextMessageIndex = projectedMessageIndex + entry.messages.count
            if lastUsageIndex < nextMessageIndex {
                usageEntryId = entry.sourceEntry.id
                break
            }
            projectedMessageIndex = nextMessageIndex
        }

        let usageEntryIndex = usageEntryId.flatMap { id in branchEntries.firstIndex { $0.id == id } } ?? -1
        var latestInvalidatingEntryIndex = -1
        for i in stride(from: branchEntries.count - 1, through: 0, by: -1) {
            let entry = branchEntries[i]
            if entry.type == "context_edit" || entry.type == "compaction" {
                latestInvalidatingEntryIndex = i
                break
            }
        }
        if usageEntryIndex > latestInvalidatingEntryIndex { return estimate }
    }

    let currentSystem = getCurrentSystemMessage(projection.messages.compactMap(\.llmMessage))
    var tokens = currentSystem.map { estimateTokens(.system($0)) } ?? 0
    for message in projection.messages {
        if message.role != "system" { tokens += estimateTokens(message) }
    }
    return ContextUsageEstimate(tokens: tokens, usageTokens: 0, trailingTokens: tokens, lastUsageIndex: nil)
}

/**
 * Check if compaction should trigger based on context usage.
 */
public func shouldCompact(_ contextTokens: Int, _ contextWindow: Int, _ settings: CompactionSettings) -> Bool {
    if !settings.enabled { return false }
    return contextTokens > contextWindow - settings.reserveTokens
}

// ============================================================================
// Cut point detection
// ============================================================================

private let ESTIMATED_IMAGE_CHARS = 4800

private func estimateTextAndImageContentChars(_ content: [UserContent]) -> Int {
    var chars = 0
    for block in content {
        switch block {
        case .text(let text):
            chars += text.text.utf16.count
        case .image:
            chars += ESTIMATED_IMAGE_CHARS
        }
    }
    return chars
}

private func estimateTextAndImageContentChars(_ content: UserMessageContent) -> Int {
    switch content {
    case .string(let text): return text.utf16.count
    case .blocks(let blocks): return estimateTextAndImageContentChars(blocks)
    }
}

private func estimateTextAndImageContentChars(_ content: SystemMessageContent) -> Int {
    switch content {
    case .string(let text): return text.utf16.count
    case .blocks(let blocks): return blocks.reduce(0) { $0 + $1.text.utf16.count }
    }
}

private func ceilDiv4(_ chars: Int) -> Int {
    Int((Double(chars) / 4).rounded(.up))
}

/**
 * Estimate token count for a message using chars/4 heuristic.
 * This is conservative (overestimates tokens).
 */
public func estimateTokens(_ message: AgentMessage) -> Int {
    var chars = 0

    switch message {
    case .system(let system):
        chars = estimateTextAndImageContentChars(system.content)
        if let sections = system.sections {
            for section in sections {
                if let text = section.text { chars += text.utf16.count }
            }
        }
        if let toolsAdded = system.toolsAdded { chars += JsonValue.array(toolsAdded.map(\.json)).serialized().utf16.count }
        return ceilDiv4(chars)
    case .user(let user):
        chars = estimateTextAndImageContentChars(user.content)
        return ceilDiv4(chars)
    case .assistant(let assistant):
        for block in assistant.content {
            switch block {
            case .text(let text):
                chars += text.text.utf16.count
            case .thinking(let thinking):
                chars += thinking.thinking.utf16.count
            case .toolCall(let toolCall):
                chars += toolCall.name.utf16.count + JsonValue.object(toolCall.arguments).serialized().utf16.count
            }
        }
        return ceilDiv4(chars)
    case .toolResult(let result):
        chars = estimateTextAndImageContentChars(result.content)
        return ceilDiv4(chars)
    case .custom(let custom):
        switch custom.role {
        case "custom":
            if let customMessage = CustomMessage(message) {
                chars = estimateTextAndImageContentChars(customMessage.content)
            }
            return ceilDiv4(chars)
        case "bashExecution":
            if let bash = BashExecutionMessage(message) {
                chars = bash.command.utf16.count + bash.output.utf16.count
            }
            return ceilDiv4(chars)
        case "branchSummary", "compactionSummary":
            chars = (custom.payload["summary"]?.stringValue ?? "").utf16.count
            return ceilDiv4(chars)
        default:
            break
        }
    }

    return 0
}

private func isCutPointMessage(_ message: AgentMessage) -> Bool {
    switch message.role {
    case "user", "assistant", "bashExecution", "custom", "branchSummary", "compactionSummary":
        return true
    case "toolResult":
        return false
    default:
        return false
    }
}

private func isTurnStartMessage(_ message: AgentMessage) -> Bool {
    switch message.role {
    case "user", "bashExecution", "custom", "branchSummary", "compactionSummary":
        return true
    case "assistant", "toolResult":
        return false
    default:
        return false
    }
}

private func isTurnStartEntry(_ entry: SessionEntry) -> Bool {
    if case .compaction = entry {
        return false
    }
    return sessionEntryToContextMessages(entry).contains(where: isTurnStartMessage)
}

/**
 * Find valid cut points: indices of context-visible user-like or assistant messages.
 * Never cut at tool results (they must follow their tool call).
 * When we cut at an assistant message with tool calls, its tool results follow it
 * and will be kept.
 */
private func findValidCutPoints(_ entries: [SessionEntry], _ startIndex: Int, _ endIndex: Int) -> [Int] {
    var cutPoints: [Int] = []
    var i = startIndex
    while i < endIndex {
        let entry = entries[i]
        if case .compaction = entry {
            i += 1
            continue
        }
        if sessionEntryToContextMessages(entry).contains(where: isCutPointMessage) {
            cutPoints.append(i)
        }
        i += 1
    }
    return cutPoints
}

/**
 * Find the context-visible user-role message that starts the turn containing the given entry index.
 * Returns -1 if no turn start found before the index.
 */
public func findTurnStartIndex(_ entries: [SessionEntry], _ entryIndex: Int, _ startIndex: Int) -> Int {
    var i = entryIndex
    while i >= startIndex {
        if isTurnStartEntry(entries[i]) {
            return i
        }
        i -= 1
    }
    return -1
}

public struct CutPointResult: Sendable, Hashable {
    /** Index of first entry to keep */
    public var firstKeptEntryIndex: Int
    /** Index of user message that starts the turn being split, or -1 if not splitting */
    public var turnStartIndex: Int
    /** Whether this cut splits a turn (cut point is not a user message) */
    public var isSplitTurn: Bool
    public init(firstKeptEntryIndex: Int, turnStartIndex: Int, isSplitTurn: Bool) {
        self.firstKeptEntryIndex = firstKeptEntryIndex; self.turnStartIndex = turnStartIndex; self.isSplitTurn = isSplitTurn
    }
}

/**
 * Find the cut point in session entries that keeps approximately `keepRecentTokens`.
 *
 * Algorithm: Walk backwards from newest, accumulating estimated message sizes.
 * Stop when we've accumulated >= keepRecentTokens. Cut at that point.
 *
 * Can cut at user OR assistant messages (never tool results). When cutting at an
 * assistant message with tool calls, its tool results come after and will be kept.
 *
 * Returns CutPointResult with:
 * - firstKeptEntryIndex: the entry index to start keeping from
 * - turnStartIndex: if cutting mid-turn, the user message that started that turn
 * - isSplitTurn: whether we're cutting in the middle of a turn
 *
 * Only considers entries between `startIndex` and `endIndex` (exclusive).
 */
public func findCutPoint(
    _ entries: [SessionEntry],
    _ startIndex: Int,
    _ endIndex: Int,
    _ keepRecentTokens: Int
) -> CutPointResult {
    let cutPoints = findValidCutPoints(entries, startIndex, endIndex)

    if cutPoints.isEmpty {
        return CutPointResult(firstKeptEntryIndex: startIndex, turnStartIndex: -1, isSplitTurn: false)
    }

    // Walk backwards from newest, accumulating estimated message sizes
    var accumulatedTokens = 0
    var cutIndex = cutPoints[0] // Default: keep from first message (not header)

    var i = endIndex - 1
    while i >= startIndex {
        let entry = entries[i]
        let messageTokens = sessionEntryToContextMessages(entry).reduce(0) { sum, message in sum + estimateTokens(message) }
        if messageTokens == 0 {
            i -= 1
            continue
        }
        accumulatedTokens += messageTokens

        // Check if we've exceeded the budget
        if accumulatedTokens >= keepRecentTokens {
            // Prefer the closest valid cut point at or after this entry. If trailing
            // tool results exceed the budget by themselves, keep their preceding
            // assistant tool call instead of falling back to the first message.
            cutIndex = cutPoints.first { $0 >= i } ?? cutPoints[cutPoints.count - 1]
            break
        }
        i -= 1
    }

    // Scan backwards from cutIndex to include adjacent metadata entries that do not affect context.
    while cutIndex > startIndex {
        let prevEntry = entries[cutIndex - 1]
        // Stop at compaction boundaries or context-visible entries.
        if prevEntry.type == "compaction" || !sessionEntryToContextMessages(prevEntry).isEmpty {
            break
        }
        cutIndex -= 1
    }

    // Determine if this is a split turn
    let cutEntry = entries[cutIndex]
    let startsTurn = isTurnStartEntry(cutEntry)
    let turnStartIndex = startsTurn ? -1 : findTurnStartIndex(entries, cutIndex, startIndex)

    return CutPointResult(
        firstKeptEntryIndex: cutIndex,
        turnStartIndex: turnStartIndex,
        isSplitTurn: !startsTurn && turnStartIndex != -1
    )
}

// ============================================================================
// Summarization
// ============================================================================

let SUMMARIZATION_PROMPT = """
The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.
"""

let UPDATE_SUMMARIZATION_INSTRUCTIONS = """
Update the existing structured summary with new information. RULES:
- PRESERVE all existing information from the previous summary
- ADD new progress, decisions, and context from the new messages
- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
- UPDATE "Next Steps" based on what was accomplished
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it

Use this EXACT format:

## Goal
[Preserve existing goals, add new ones if the task expanded]

## Constraints & Preferences
- [Preserve existing, add new ones discovered]

## Progress
### Done
- [x] [Include previously done items AND newly completed items]

### In Progress
- [ ] [Current work - update based on progress]

### Blocked
- [Current blockers - remove if resolved]

## Key Decisions
- **[Decision]**: [Brief rationale] (preserve all previous, add new)

## Next Steps
1. [Update based on current state]

## Critical Context
- [Preserve important context, add new if needed]

Keep each section concise. Preserve exact file paths, function names, and error messages.
"""

let UPDATE_SUMMARIZATION_PROMPT = """
The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

\(UPDATE_SUMMARIZATION_INSTRUCTIONS)
"""

/**
 * Returns an error message when a summarization response cannot safely be persisted.
 * A length stop contains partial text and must not become a session checkpoint.
 */
public func getSummarizationFailure(_ response: AssistantMessage, _ label: String) -> String? {
    if response.stopReason == .error {
        let message = response.errorMessage ?? ""
        return "\(label) failed: \(message.isEmpty ? "Unknown error" : message)"
    }
    if response.stopReason == .length {
        return "\(label) failed: generation hit the token cap and the summary is incomplete"
    }
    return nil
}

private func createSummarizationOptions(
    _ model: Model,
    _ apiKey: String?,
    _ headers: ProviderHeaders?,
    _ env: ProviderEnv?,
    _ signal: AbortSignal?,
    _ thinkingLevel: AgentThinkingLevel?,
    _ sessionId: String?
) -> SimpleStreamOptions {
    var options = SimpleStreamOptions()
    options.signal = signal
    options.apiKey = apiKey
    options.headers = headers
    options.env = env
    options.sessionId = sessionId
    if model.reasoning, let thinkingLevel, thinkingLevel != .off {
        options.reasoning = thinkingLevel.thinkingLevel
    }
    return options
}

/**
 * Shared choke point for every compaction/branch-summary summarization call. Wraps the
 * single LLM call in {@link retryAssistantCall} so transient stream drops (e.g.
 * `terminated`, socket close) honor the configured retry policy instead of failing
 * the whole compaction on the first attempt. Deterministic errors and aborts return
 * immediately (see {@link retryAssistantCall}).
 */
public func completeSummarization(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: SimpleStreamOptions,
    _ streamFn: StreamFn? = nil,
    _ retry: RetryPolicy? = nil,
    _ callbacks: RetryCallbacks? = nil
) async throws -> AssistantMessage {
    // Avoid cache writes for one-off summaries. Reuse caller-supplied routing when available;
    // callers without a session ID, including branch summaries, receive a fresh routing ID.
    var requestOptions = options
    requestOptions.cacheRetention = CacheRetention.none
    requestOptions.sessionId = try options.sessionId ?? uuidv7()
    let finalOptions = requestOptions
    let produce: @Sendable () async throws -> AssistantMessage = {
        if let streamFn {
            return await (try await streamFn(model, context, finalOptions)).result()
        }
        // Swift: `completeSimple` takes a `Context`; the transcript already leads with its system message.
        return try await completeSimple(model, Context(messages: context.messages), finalOptions)
    }
    return try await retryAssistantCall(produce, retry, finalOptions.signal, callbacks)
}

/**
 * Generate a summary of the conversation using the LLM.
 * If previousSummary is provided, uses the update prompt to merge.
 */
public func generateSummary(
    _ currentMessages: [AgentMessage],
    _ model: Model,
    // Unused. Kept for existing callers; summaries use the model's output limit (#9512).
    _ _reserveTokens: Int?,
    _ apiKey: String?,
    _ headers: ProviderHeaders? = nil,
    _ signal: AbortSignal? = nil,
    _ customInstructions: String? = nil,
    _ previousSummary: String? = nil,
    _ thinkingLevel: AgentThinkingLevel? = nil,
    _ streamFn: StreamFn? = nil,
    _ env: ProviderEnv? = nil,
    _ retry: RetryPolicy? = nil,
    _ callbacks: RetryCallbacks? = nil,
    _ sessionId: String? = nil
) async throws -> String {
    try await generateSummaryWithUsage(
        currentMessages,
        model,
        _reserveTokens,
        apiKey,
        headers,
        signal,
        customInstructions,
        previousSummary,
        thinkingLevel,
        streamFn,
        env,
        retry,
        callbacks,
        sessionId
    ).text
}

/** Build the provider context for a standalone summary request. */
private func buildSummarizationContext(_ promptText: String) -> TranscriptContext {
    normalizeContext(Context(
        systemPrompt: SUMMARIZATION_SYSTEM_PROMPT,
        messages: [
            .user(UserMessage(
                content: .blocks([.text(TextContent(text: promptText))]),
                timestamp: dateNow()
            )),
        ]
    ))
}

/** Generate or update a conversation summary and return its provider usage. */
public func generateSummaryWithUsage(
    _ currentMessages: [AgentMessage],
    _ model: Model,
    // Unused. Kept for existing callers; summaries use the model's output limit (#9512).
    _ _reserveTokens: Int?,
    _ apiKey: String?,
    _ headers: ProviderHeaders? = nil,
    _ signal: AbortSignal? = nil,
    _ customInstructions: String? = nil,
    _ previousSummary: String? = nil,
    _ thinkingLevel: AgentThinkingLevel? = nil,
    _ streamFn: StreamFn? = nil,
    _ env: ProviderEnv? = nil,
    _ retry: RetryPolicy? = nil,
    _ callbacks: RetryCallbacks? = nil,
    _ sessionId: String? = nil
) async throws -> (text: String, usage: Usage) {
    // Use update prompt if we have a previous summary, otherwise initial prompt
    let hasPreviousSummary = previousSummary?.isEmpty == false
    var basePrompt = hasPreviousSummary ? UPDATE_SUMMARIZATION_PROMPT : SUMMARIZATION_PROMPT
    if let customInstructions, !customInstructions.isEmpty {
        basePrompt = "\(basePrompt)\n\nAdditional focus: \(customInstructions)"
    }

    // Serialize conversation to text so model doesn't try to continue it
    // Convert to LLM messages first (handles custom types like bashExecution, custom, etc.)
    let llmMessages = convertToLlm(currentMessages)
    let conversationText = serializeConversation(llmMessages)

    // Build the prompt with conversation wrapped in tags
    var promptText = "<conversation>\n\(conversationText)\n</conversation>\n\n"
    if hasPreviousSummary, let previousSummary {
        promptText += "<previous-summary>\n\(previousSummary)\n</previous-summary>\n\n"
    }
    promptText += basePrompt

    let completionOptions = createSummarizationOptions(model, apiKey, headers, env, signal, thinkingLevel, sessionId)

    let response = try await completeSummarization(
        model,
        buildSummarizationContext(promptText),
        completionOptions,
        streamFn,
        retry,
        callbacks
    )

    if let failure = getSummarizationFailure(response, "Summarization") {
        throw PiError(failure)
    }
    if response.content.contains(where: { $0.type == "toolCall" }) {
        throw PiError("Summarization attempted to call a tool")
    }

    let textContent = contentText(response.content)

    return (text: textContent, usage: response.usage)
}

// ============================================================================
// Compaction Preparation (for extensions)
// ============================================================================

public struct CompactionPreparation: Sendable {
    /** UUID of first entry to keep */
    public var firstKeptEntryId: String
    /** Messages that will be summarized and discarded */
    public var messagesToSummarize: [AgentMessage]
    /** Messages that will be turned into turn prefix summary (if splitting) */
    public var turnPrefixMessages: [AgentMessage]
    /** Whether this is a split turn (cut point in middle of turn) */
    public var isSplitTurn: Bool
    public var tokensBefore: Int
    /** Summary from previous compaction, for iterative update */
    public var previousSummary: String?
    /** File operations extracted from messagesToSummarize */
    public var fileOps: FileOperations
    /** Compaction settions from settings.jsonl	*/
    public var settings: CompactionSettings
    public init(firstKeptEntryId: String, messagesToSummarize: [AgentMessage], turnPrefixMessages: [AgentMessage], isSplitTurn: Bool, tokensBefore: Int, previousSummary: String? = nil, fileOps: FileOperations, settings: CompactionSettings) {
        self.firstKeptEntryId = firstKeptEntryId; self.messagesToSummarize = messagesToSummarize; self.turnPrefixMessages = turnPrefixMessages
        self.isSplitTurn = isSplitTurn; self.tokensBefore = tokensBefore; self.previousSummary = previousSummary; self.fileOps = fileOps; self.settings = settings
    }
}

private func isProjectedTurnStart(_ entry: ProjectedSessionEntry) -> Bool {
    if case .compaction = entry.sourceEntry { return false }
    return entry.messages.contains(where: isTurnStartMessage)
}

private func findProjectedTurnStartIndex(_ entries: [ProjectedSessionEntry], _ entryIndex: Int, _ startIndex: Int) -> Int {
    var i = entryIndex
    while i >= startIndex {
        if isProjectedTurnStart(entries[i]) { return i }
        i -= 1
    }
    return -1
}

private func findProjectedCutPoint(
    _ entries: [ProjectedSessionEntry],
    _ startIndex: Int,
    _ endIndex: Int,
    _ keepRecentTokens: Int
) -> CutPointResult {
    var cutPoints: [Int] = []
    for i in startIndex..<max(startIndex, endIndex) {
        let entry = entries[i]
        if entry.sourceEntry.type != "compaction" && entry.messages.contains(where: isCutPointMessage) { cutPoints.append(i) }
    }
    if cutPoints.isEmpty {
        return CutPointResult(firstKeptEntryIndex: startIndex, turnStartIndex: -1, isSplitTurn: false)
    }

    var accumulatedTokens = 0
    var exceededBudget = false
    var cutIndex = cutPoints[0]
    var i = endIndex - 1
    while i >= startIndex {
        let messageTokens = entries[i].messages.reduce(0) { sum, message in sum + estimateTokens(message) }
        if messageTokens == 0 {
            i -= 1
            continue
        }
        accumulatedTokens += messageTokens
        if accumulatedTokens >= keepRecentTokens {
            exceededBudget = true
            cutIndex = cutPoints.first { $0 >= i } ?? cutPoints[cutPoints.count - 1]
            break
        }
        i -= 1
    }

    // A recovery attempt and its omission edits are context-invisible after the last
    // visible input. Advance only for a closed suffix containing an omitted assistant
    // attempt; arbitrary metadata must not move the cut past unsent input.
    let suffix = cutIndex + 1 < endIndex ? Array(entries[(cutIndex + 1)..<endIndex]) : []
    let isIntrinsicallyVisible = { (entry: ProjectedSessionEntry) -> Bool in
        entry.sourceEntry.type != "context_edit" && !sessionEntryToContextMessages(entry.sourceEntry).isEmpty
    }
    let isOmitted = { (entry: ProjectedSessionEntry) -> Bool in
        isIntrinsicallyVisible(entry) && entry.messages.isEmpty
    }
    let omittedSuffixIds = Set(suffix.filter(isOmitted).map(\.sourceEntry.id))
    let hasExternalReplacement = suffix.contains { entry in
        guard case .contextEdit(let edit) = entry.sourceEntry else { return false }
        return edit.replacement != nil && !omittedSuffixIds.contains(edit.targetId)
    }
    let isRecoveryOmissionSuffix =
        exceededBudget &&
        !hasExternalReplacement &&
        suffix.contains { entry in
            guard case .message(let e) = entry.sourceEntry else { return false }
            return e.message.role == "assistant" && isOmitted(entry)
        } &&
        suffix.allSatisfy { entry in
            entry.sourceEntry.type != "compaction" && (!isIntrinsicallyVisible(entry) || isOmitted(entry))
        }
    if isRecoveryOmissionSuffix { cutIndex += 1 }

    while cutIndex > startIndex {
        let previous = entries[cutIndex - 1]
        if previous.sourceEntry.type == "compaction" || !previous.messages.isEmpty { break }
        cutIndex -= 1
    }
    // Swift: upstream reads `entries[cutIndex]` (undefined past the end -> not a turn start).
    let startsTurn = cutIndex < entries.count ? isProjectedTurnStart(entries[cutIndex]) : false
    let turnStartIndex = startsTurn ? -1 : findProjectedTurnStartIndex(entries, min(cutIndex, entries.count - 1), startIndex)
    return CutPointResult(
        firstKeptEntryIndex: cutIndex,
        turnStartIndex: turnStartIndex,
        isSplitTurn: !startsTurn && turnStartIndex != -1
    )
}

public func prepareCompaction(
    _ pathEntries: [SessionEntry],
    _ settings: CompactionSettings
) -> CompactionPreparation? {
    if let last = pathEntries.last, last.type == "compaction" {
        return nil
    }

    let projection = buildSessionProjection(pathEntries)
    let projectedEntries = projection.entries
    let sourceEntries = projectedEntries.map(\.sourceEntry)
    // The newest compaction is projected first. Older compaction entries can still
    // occur in its retained raw range, but their projected contribution is empty.
    let prevCompactionIndex = projectedEntries.firstIndex {
        $0.sourceEntry.type == "compaction" && !$0.messages.isEmpty
    } ?? -1

    var previousSummary: String?
    var boundaryStart = 0
    if prevCompactionIndex >= 0 {
        previousSummary = projectedEntries[prevCompactionIndex].sourceEntry.compactionEntry?.summary
        // The canonical projection has already selected the previous compaction's retained tail.
        boundaryStart = prevCompactionIndex + 1
    }
    let boundaryEnd = projectedEntries.count
    let tokensBefore = estimateProjectedContextTokens(projection, pathEntries).tokens
    let cutPoint = findProjectedCutPoint(projectedEntries, boundaryStart, boundaryEnd, settings.keepRecentTokens)

    guard cutPoint.firstKeptEntryIndex >= 0, cutPoint.firstKeptEntryIndex < projectedEntries.count else { return nil }
    let firstKeptEntry = projectedEntries[cutPoint.firstKeptEntryIndex].sourceEntry
    if firstKeptEntry.id.isEmpty { return nil }
    let firstKeptEntryId = firstKeptEntry.id
    let historyEnd = cutPoint.isSplitTurn ? cutPoint.turnStartIndex : cutPoint.firstKeptEntryIndex

    let messagesToSummarize = (boundaryStart < historyEnd ? Array(projectedEntries[boundaryStart..<historyEnd]) : [])
        .flatMap(getMessagesFromProjectedEntryForCompaction)
    let turnPrefixMessages = cutPoint.isSplitTurn && cutPoint.turnStartIndex < cutPoint.firstKeptEntryIndex
        ? Array(projectedEntries[cutPoint.turnStartIndex..<cutPoint.firstKeptEntryIndex])
            .flatMap(getMessagesFromProjectedEntryForCompaction)
        : []

    if messagesToSummarize.isEmpty && turnPrefixMessages.isEmpty { return nil }

    // Extract file operations from edited model-visible messages and the previous compaction.
    var fileOps = extractFileOperations(messagesToSummarize, sourceEntries, prevCompactionIndex)

    // Also extract file ops from turn prefix if splitting
    if cutPoint.isSplitTurn {
        for msg in turnPrefixMessages {
            extractFileOpsFromMessage(msg, &fileOps)
        }
    }

    return CompactionPreparation(
        firstKeptEntryId: firstKeptEntryId,
        messagesToSummarize: messagesToSummarize,
        turnPrefixMessages: turnPrefixMessages,
        isSplitTurn: cutPoint.isSplitTurn,
        tokensBefore: tokensBefore,
        previousSummary: previousSummary,
        fileOps: fileOps,
        settings: settings
    )
}

// ============================================================================
// Main compaction function
// ============================================================================

let TURN_PREFIX_SUMMARIZATION_PROMPT = """
The messages above are earlier context from an ongoing conversation. Later messages are stored separately and do not need to be reconstructed.

Create a concise checkpoint of the user's request and the progress shown above. This checkpoint will be placed before the later messages so the conversation can continue with the necessary context.

## Original Request
[What did the user ask for?]

## Progress So Far
- [Key decisions and work completed in these messages]

## Context Needed to Continue
- [Information from these messages needed to understand the later work]

Only summarize information explicitly present above. Do not infer or recreate later messages.
"""

/**
 * Generate summaries for compaction using prepared data.
 * Returns CompactionResult - SessionManager adds uuid/parentUuid when saving.
 *
 * @param preparation - Pre-calculated preparation from prepareCompaction()
 * @param customInstructions - Optional custom focus for the summary
 * @param sessionId - Optional routing session ID forwarded without enabling prompt caching
 */
public func compact(
    _ preparation: CompactionPreparation,
    _ model: Model,
    _ apiKey: String?,
    _ headers: ProviderHeaders? = nil,
    _ customInstructions: String? = nil,
    _ signal: AbortSignal? = nil,
    _ thinkingLevel: AgentThinkingLevel? = nil,
    _ streamFn: StreamFn? = nil,
    _ env: ProviderEnv? = nil,
    _ retry: RetryPolicy? = nil,
    _ callbacks: RetryCallbacks? = nil,
    _ sessionId: String? = nil
) async throws -> CompactionResult {
    let firstKeptEntryId = preparation.firstKeptEntryId
    let messagesToSummarize = preparation.messagesToSummarize
    let turnPrefixMessages = preparation.turnPrefixMessages
    let isSplitTurn = preparation.isSplitTurn
    let tokensBefore = preparation.tokensBefore
    let previousSummary = preparation.previousSummary
    let fileOps = preparation.fileOps

    // Generate summaries and merge into one
    var summary: String
    var summaryUsage: Usage

    if isSplitTurn && !turnPrefixMessages.isEmpty {
        var historyText = previousSummary ?? "No prior history."
        var historyUsage: Usage?
        if !messagesToSummarize.isEmpty {
            let historyResult = try await generateSummaryWithUsage(
                messagesToSummarize,
                model,
                nil,
                apiKey,
                headers,
                signal,
                customInstructions,
                previousSummary,
                thinkingLevel,
                streamFn,
                env,
                retry,
                callbacks,
                sessionId
            )
            historyText = historyResult.text
            historyUsage = historyResult.usage
        }
        let turnPrefixResult = try await generateTurnPrefixSummary(
            turnPrefixMessages,
            model,
            apiKey,
            headers,
            env,
            signal,
            thinkingLevel,
            streamFn,
            retry,
            callbacks,
            sessionId
        )
        // Merge into single summary
        summary = "\(historyText)\n\n---\n\n**Turn Context (split turn):**\n\n\(turnPrefixResult.text)"
        summaryUsage = historyUsage.map { combineUsage($0, turnPrefixResult.usage) } ?? turnPrefixResult.usage
    } else {
        // Just generate history summary
        let result = try await generateSummaryWithUsage(
            messagesToSummarize,
            model,
            nil,
            apiKey,
            headers,
            signal,
            customInstructions,
            previousSummary,
            thinkingLevel,
            streamFn,
            env,
            retry,
            callbacks,
            sessionId
        )
        summary = result.text
        summaryUsage = result.usage
    }

    // Compute file lists and append to summary
    let (readFiles, modifiedFiles) = computeFileLists(fileOps)
    summary += formatFileOperations(readFiles, modifiedFiles)

    if firstKeptEntryId.isEmpty {
        throw PiError("First kept entry has no UUID - session may need migration")
    }

    return CompactionResult(
        summary: summary,
        firstKeptEntryId: firstKeptEntryId,
        tokensBefore: tokensBefore,
        usage: summaryUsage,
        details: CompactionDetails(readFiles: readFiles, modifiedFiles: modifiedFiles).json
    )
}

/**
 * Generate a summary for a turn prefix (when splitting a turn).
 */
private func generateTurnPrefixSummary(
    _ messages: [AgentMessage],
    _ model: Model,
    _ apiKey: String?,
    _ headers: ProviderHeaders? = nil,
    _ env: ProviderEnv? = nil,
    _ signal: AbortSignal? = nil,
    _ thinkingLevel: AgentThinkingLevel? = nil,
    _ streamFn: StreamFn? = nil,
    _ retry: RetryPolicy? = nil,
    _ callbacks: RetryCallbacks? = nil,
    _ sessionId: String? = nil
) async throws -> (text: String, usage: Usage) {
    let llmMessages = convertToLlm(messages)
    let conversationText = serializeConversation(llmMessages)
    let promptText = "# Conversation\n\(conversationText)\n\n# Instructions\n\(TURN_PREFIX_SUMMARIZATION_PROMPT)"

    let response = try await completeSummarization(
        model,
        buildSummarizationContext(promptText),
        createSummarizationOptions(model, apiKey, headers, env, signal, thinkingLevel, sessionId),
        streamFn,
        retry,
        callbacks
    )

    if let failure = getSummarizationFailure(response, "Turn prefix summarization") {
        throw PiError(failure)
    }
    if response.content.contains(where: { $0.type == "toolCall" }) {
        throw PiError("Turn prefix summarization attempted to call a tool")
    }

    return (
        text: contentText(response.content),
        usage: response.usage
    )
}
