import Foundation
import Testing
@testable import PiUI

@Suite struct MarkdownTests {
    @Test func preservesFencedCodeAndIncompleteStreams() throws {
        let code = "let café = \"你好\"\n\n    print(café)\n"
        let open = MarkdownParser.parse("```swift\n" + code)
        #expect(open == [.code(language: "swift", source: code)])
        #expect(MarkdownParser.parse("```swift\n" + code + "```\n\nDone.") == open + [.paragraph([MarkdownRun(text: "Done.")])])
        #expect(MarkdownParser.parse("    a\n    b\n") == [.code(language: nil, source: "a\nb\n")])
    }

    @Test func preservesOrderedStartsNestedListsAndCheckboxes() throws {
        let parsed = MarkdownParser.parse("3. First\n4. Second\n   - [x] Ready\n   - [ ] Waiting\n")
        guard case .list(let list) = try #require(parsed.first),
              case .list(let nested) = try #require(list.last?.blocks.last) else {
            Issue.record("Expected nested lists"); return
        }
        #expect(list.map(\.marker) == ["3.", "4."])
        #expect(nested.map(\.checked) == [true, false])
        #expect(nested[0].blocks == [.paragraph([MarkdownRun(text: "Ready")])])
    }

    @Test func handlesTablesQuotesAndHeadings() throws {
        let parsed = MarkdownParser.parse("# Heading\n\n> Quote\n\n| Name | Value |\n| :--- | ---: |\n| A | `42` |\n\n---\n")
        #expect(parsed.count == 4)
        #expect(parsed[0] == .heading(1, [MarkdownRun(text: "Heading")]))
        #expect(parsed[1] == .quote([.paragraph([MarkdownRun(text: "Quote")])]))
        guard case .table(let headers, let rows, let alignments) = parsed[2] else {
            Issue.record("Expected a table"); return
        }
        #expect(headers.count == 2)
        #expect(rows[0][1] == [MarkdownRun(text: "42", code: true)])
        #expect(alignments == [.left, .right])
        #expect(parsed[3] == .divider)
    }

    @Test func composesInlineStylesWithoutChangingLiteralText() throws {
        let parsed = MarkdownParser.parse("**bold *both*** and ~~old~~, `a < b`  \nnext\nline -- straight \"quotes\".")
        guard case .paragraph(let runs) = try #require(parsed.first) else { return }
        #expect(runs.contains { $0.text == "both" && $0.strong && $0.emphasis })
        #expect(runs.contains { $0.text == "old" && $0.strike })
        #expect(runs.contains { $0.text == "a < b" && $0.code })
        #expect(runs.map(\.text).joined() == "bold both and old, a < b\nnext line -- straight \"quotes\".")
    }

    @Test func neverActivatesExecutableURLsOrFetchesImages() throws {
        let parsed = MarkdownParser.parse("[safe](https://example.com) [script](javascript:alert) [file](file:///tmp/a) ![diagram](https://example.com/private.png) <b>raw</b>")
        guard case .paragraph(let runs) = try #require(parsed.first) else { return }
        #expect(runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com"])
        #expect(runs.map(\.text).joined().contains("[Image: diagram]"))
        #expect(runs.map(\.text).joined().contains("<b>raw</b>"))
        #expect(MarkdownParser.safeLink("MAILTO:hello@example.com") != nil)
        #expect(MarkdownParser.safeLink("../local/file") == nil)
    }

    @MainActor @Test func streamingConvergesAndCanRestartAfterCancellation() async throws {
        let rendering = MarkdownRendering()
        for index in 0..<80 { rendering.update("## Reply \(index)\n\n```swift\nlet n = \(index)") }
        let final = "## Finished\n\n```swift\nlet n = 80\n```"
        rendering.update(final)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while rendering.blocks != MarkdownParser.parse(final), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(rendering.blocks == MarkdownParser.parse(final))
        rendering.update("old content"); rendering.cancel()
        rendering.update("new content")
        while rendering.blocks != MarkdownParser.parse("new content"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(rendering.blocks == MarkdownParser.parse("new content"))
        rendering.cancel()
    }
}
