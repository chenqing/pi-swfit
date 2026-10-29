import PiAI
import PiAgent

/// Text restored to the editor by upstream tree navigation. Attachments remain in the
/// original transcript; this text composer does not silently resend them.
public func sessionEntryEditorText(_ entry: SessionEntry) -> String? {
    let content: UserMessageContent?
    switch entry {
    case .message(let entry):
        guard case .user(let user) = entry.message else { return nil }
        content = user.content
    case .customMessage(let entry): content = entry.content
    default: return nil
    }
    switch content {
    case .string(let text): return text
    case .blocks(let blocks): return blocks.compactMap(\.textContent?.text).joined(separator: "")
    case nil: return ""
    }
}
