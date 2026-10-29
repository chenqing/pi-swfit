import Foundation
import Testing
import PiAI
@testable import PiCodingAgent

// Cases ported from prompt-templates.test.ts @ aee933269ba79b84e7b7454097c1d4c426021d82.
struct PromptTemplateTests {
    @Test func quotesAndEmptyArgumentsMatchUpstream() {
        #expect(parseCommandArgs("one \"two three\" '' four") == ["one", "two three", "", "four"])
        #expect(parseCommandArgs("ab\"cd ef\"gh '\"quoted\"' \"unfinished") == ["abcd efgh", "\"quoted\"", "unfinished"])
        #expect(parseCommandArgs("中文\n🎉\tcafé") == ["中文", "🎉", "café"])
        #expect(parseCommandArgs(#"a\b \"#) == [#"a\b"#, #"\"#])
    }
    @Test func replacementIsSinglePassAndPreservesLiteralValues() {
        #expect(substituteArgs("$1: $@ ($ARGUMENTS)", ["$2", "$ARGUMENTS"]) == "$2: $2 $ARGUMENTS ($2 $ARGUMENTS)")
        #expect(substituteArgs("${3:-$ARGUMENTS}", ["a", "b"]) == "$ARGUMENTS")
        #expect(substituteArgs("$0 $2 $100 $1.5", ["x"]) == "   x.5")
        #expect(substituteArgs("$A $$ $ $ARGS $arguments", ["x"]) == "$A $$ $ $ARGS $arguments")
        #expect(substituteArgs("$1\n$2", ["中文🎉", "line\nnext"]) == "中文🎉\nline\nnext")
    }
    @Test func defaultsSlicesAndBoundariesMatchUpstream() {
        #expect(substituteArgs("${1:-seven steps}|${@:-all}|${ARGUMENTS:-none}", []) == "seven steps|all|none")
        #expect(substituteArgs("${1:-brief}|$ARGUMENTS", ["", "two"]) == "brief| two")
        #expect(substituteArgs("${@:2}|${@:2:2}|${@:0}|${@:1:0}|${@:99}", ["a", "b", "c", "d"]) == "b c d|b c|a b c d||")
        #expect(substituteArgs("${@:2:999999999999999999999999}|${@:999999999999999999999}", ["a", "b"]) == "b|")
        #expect(substituteArgs("${@:1}", ["${@:2}", "test"]) == "${@:2} test")
    }
    @Test func loadingIsNonrecursiveAndReportsMalformedYaml() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("prompts/nested"), withIntermediateDirectories: true)
        try "---\ndescription: Describe files\nargument-hint: <file>\n---\nRead $1".write(to: root.appendingPathComponent("prompts/review.md"), atomically: true, encoding: .utf8)
        try "Nested".write(to: root.appendingPathComponent("prompts/nested/hidden.md"), atomically: true, encoding: .utf8)
        try "---\ndescription: [broken\n---\ninvalid".write(to: root.appendingPathComponent("prompts/invalid.md"), atomically: true, encoding: .utf8)
        let loaded = loadPromptTemplates(.init(cwd: root.path, agentDir: root.path, includeDefaults: true))
        #expect(loaded.templates.map(\.name) == ["review"])
        #expect(loaded.templates.first?.argumentHint == "<file>")
        #expect(loaded.diagnostics.count == 1)
        #expect(expandPromptTemplate("/review \"文件 one\"", templates: loaded.templates) == "Read 文件 one")
        #expect(expandPromptTemplate("/missing", templates: loaded.templates) == "/missing")
        #expect(expandPromptTemplate("literal /review", templates: loaded.templates) == "literal /review")
    }
}
