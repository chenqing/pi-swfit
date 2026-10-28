import Foundation
import Markdown

// A value-only projection keeps cmark's tree off the main actor and out of SwiftUI state.
struct MarkdownRun: Equatable, Sendable {
    var text: String
    var emphasis = false
    var strong = false
    var strike = false
    var code = false
    var link: URL?
}

indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownRun])
    case heading(Int, [MarkdownRun])
    case code(language: String?, source: String)
    case quote([MarkdownBlock])
    case list([MarkdownListItem])
    case table(headers: [[MarkdownRun]], rows: [[[MarkdownRun]]], alignments: [MarkdownAlignment])
    case divider
}
struct MarkdownListItem: Equatable, Sendable {
    var marker: String
    var checked: Bool?
    var blocks: [MarkdownBlock]
}
enum MarkdownAlignment: Equatable, Sendable { case left, center, right }

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        blocks(Document(parsing: source, options: [.disableSmartOpts]))
    }
    static func safeLink(_ destination: String?) -> URL? {
        guard let destination, let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return nil }
        return url
    }
    private static func blocks(_ parent: any Markup) -> [MarkdownBlock] {
        parent.children.flatMap { node -> [MarkdownBlock] in
            switch node {
            case let heading as Heading: return [.heading(heading.level, inline(heading))]
            case let code as CodeBlock: return [.code(language: code.language, source: code.code)]
            case let quote as BlockQuote: return [.quote(blocks(quote))]
            case let list as OrderedList:
                return [.list(list.listItems.enumerated().map { item($0.element, marker: "\(UInt($0.offset) + list.startIndex).") })]
            case let list as UnorderedList:
                return [.list(list.listItems.map { item($0, marker: "•") })]
            case let table as Table:
                return [.table(headers: table.head.cells.map { inline($0) },
                               rows: table.body.rows.map { $0.cells.map { inline($0) } },
                               alignments: table.columnAlignments.map { $0 == .center ? .center : $0 == .right ? .right : .left })]
            case is ThematicBreak: return [.divider]
            case let html as HTMLBlock: return [.paragraph([MarkdownRun(text: html.rawHTML)])]
            case is Paragraph: return [.paragraph(inline(node))]
            default: return blocks(node)
            }
        }
    }
    private static func item(_ item: ListItem, marker: String) -> MarkdownListItem {
        MarkdownListItem(marker: marker, checked: item.checkbox.map { $0 == .checked }, blocks: blocks(item))
    }
    private static func inline(_ parent: any Markup, style: MarkdownRun = MarkdownRun(text: "")) -> [MarkdownRun] {
        parent.children.flatMap { node -> [MarkdownRun] in
            var next = style
            switch node {
            case let text as Markdown.Text: next.text = text.string; return [next]
            case let code as InlineCode: next.text = code.code; next.code = true; return [next]
            case is SoftBreak: next.text = " "; return [next]
            case is LineBreak: next.text = "\n"; return [next]
            case is Emphasis: next.emphasis = true
            case is Strong: next.strong = true
            case is Strikethrough: next.strike = true
            case let link as Markdown.Link: next.link = safeLink(link.destination)
            case let html as InlineHTML: next.text = html.rawHTML; return [next]
            case let image as Markdown.Image:
                // Images remain descriptive text; rendering a reply never fetches remote assets.
                next.text = "[Image: \(image.plainText)]"; return [next]
            default: break
            }
            return inline(node, style: next)
        }
    }
}
