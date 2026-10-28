/**
 * Shared utilities for compaction and branch summarization.
 */

import Foundation
import PiAI
import PiAgent

// Port of packages/coding-agent/src/core/compaction/utils.ts

// ============================================================================
// File Operation Tracking
// ============================================================================

public struct FileOperations: Sendable {
    public var read: Set<String>
    public var written: Set<String>
    public var edited: Set<String>
    public init(read: Set<String> = [], written: Set<String> = [], edited: Set<String> = []) {
        self.read = read; self.written = written; self.edited = edited
    }
}

public func createFileOps() -> FileOperations {
    FileOperations(
        read: [],
        written: [],
        edited: []
    )
}

/**
 * Extract file operations from tool calls in an assistant message, or from the nested calls
 * recorded on a tool result.
 */
public func extractFileOpsFromMessage(_ message: AgentMessage, _ fileOps: inout FileOperations) {
    if case .toolResult(let result) = message {
        // Calls made from codemode scripts are recorded on the script's result.
        for call in result.nestedCalls?.calls ?? [] { addFileOp(call.name, call.arguments, &fileOps) }
        return
    }
    guard case .assistant(let assistant) = message else { return }

    for block in assistant.content {
        guard case .toolCall(let toolCall) = block else { continue }
        addFileOp(toolCall.name, toolCall.arguments, &fileOps)
    }
}

private func addFileOp(_ toolName: String, _ args: JsonObject?, _ fileOps: inout FileOperations) {
    guard let path = args?["path"]?.stringValue, !path.isEmpty else { return }
    switch toolName {
    case "read":
        fileOps.read.insert(path)
    case "write":
        fileOps.written.insert(path)
    case "edit":
        fileOps.edited.insert(path)
    default:
        break
    }
}

/// `Array.prototype.sort()` default order (UTF-16 code units).
func jsSortStrings(_ values: [String]) -> [String] {
    values.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
}

/**
 * Compute final file lists from file operations.
 * Returns readFiles (files only read, not modified) and modifiedFiles.
 */
public func computeFileLists(_ fileOps: FileOperations) -> (readFiles: [String], modifiedFiles: [String]) {
    let modified = fileOps.edited.union(fileOps.written)
    let readOnly = jsSortStrings(fileOps.read.filter { !modified.contains($0) })
    let modifiedFiles = jsSortStrings(Array(modified))
    return (readFiles: readOnly, modifiedFiles: modifiedFiles)
}

/**
 * Format file operations as XML tags for summary.
 */
public func formatFileOperations(_ readFiles: [String], _ modifiedFiles: [String]) -> String {
    var sections: [String] = []
    if !readFiles.isEmpty {
        sections.append("<read-files>\n\(readFiles.joined(separator: "\n"))\n</read-files>")
    }
    if !modifiedFiles.isEmpty {
        sections.append("<modified-files>\n\(modifiedFiles.joined(separator: "\n"))\n</modified-files>")
    }
    if sections.isEmpty { return "" }
    return "\n\n\(sections.joined(separator: "\n\n"))"
}

// ============================================================================
// Message Serialization
// ============================================================================

/** Maximum characters for a tool result in serialized summaries. */
let TOOL_RESULT_MAX_CHARS = 2000

/// `text.slice(0, n)` on UTF-16 code units.
func jsSlicePrefix(_ text: String, _ count: Int) -> String {
    let utf16 = Array(text.utf16.prefix(max(0, count)))
    return String(decoding: utf16, as: UTF16.self)
}

/**
 * Truncate text to a maximum character length for summarization.
 * Keeps the beginning and appends a truncation marker.
 */
func truncateForSummary(_ text: String, _ maxChars: Int) -> String {
    let length = text.utf16.count
    if length <= maxChars { return text }
    let truncatedChars = length - maxChars
    return "\(jsSlicePrefix(text, maxChars))\n\n[... \(truncatedChars) more characters truncated]"
}

/**
 * Serialize LLM messages to text for summarization.
 * This prevents the model from treating it as a conversation to continue.
 * Call convertToLlm() first to handle custom message types.
 *
 * Tool results are truncated to keep the summarization request within
 * reasonable token budgets. Full content is not needed for summarization.
 *
 * Thinking is omitted. Providers return summaries of the real reasoning, and
 * replayed thinking is often not part of the model's live context: for example,
 * a block that does not match its request is dropped. Including it can make the
 * summarization request larger than the context it summarizes. Visible text,
 * tool calls, and tool results record what happened.
 */
public func serializeConversation(_ messages: [Message]) -> String {
    var parts: [String] = []

    for msg in messages {
        switch msg {
        case .user(let user):
            let content = contentText(user.content, separator: "")
            if !content.isEmpty { parts.append("[User]: \(content)") }
        case .assistant(let assistant):
            var toolCalls: [String] = []

            for block in assistant.content {
                if case .toolCall(let toolCall) = block {
                    let args = toolCall.arguments
                    let argsStr = args
                        .map { k, v in "\(k)=\(v.serialized())" }
                        .joined(separator: ", ")
                    toolCalls.append("\(toolCall.name)(\(argsStr))")
                }
            }

            if assistant.content.contains(where: { $0.type == "text" }) {
                parts.append("[Assistant]: \(contentText(assistant.content))")
            }
            if !toolCalls.isEmpty {
                parts.append("[Assistant tool calls]: \(toolCalls.joined(separator: "; "))")
            }
        case .toolResult(let result):
            let content = contentText(result.content, separator: "")
            if !content.isEmpty {
                parts.append("[Tool result]: \(truncateForSummary(content, TOOL_RESULT_MAX_CHARS))")
            }
        case .system:
            break
        }
    }

    return parts.joined(separator: "\n\n")
}

// ============================================================================
// Summarization System Prompt
// ============================================================================

public let SUMMARIZATION_SYSTEM_PROMPT = """
You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
"""
