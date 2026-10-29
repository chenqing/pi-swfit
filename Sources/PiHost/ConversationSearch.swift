import Foundation

/// Compact context for desktop search results, using character boundaries for Unicode text.
public enum ConversationSearch {
    public static func excerpt(in text: String, matching query: String, limit: Int = 110) -> String? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(match.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: max(limit, text.distance(from: start, to: match.upperBound)), limitedBy: text.endIndex) ?? text.endIndex
        let snippet = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + snippet + (end < text.endIndex ? "…" : "")
    }
}
