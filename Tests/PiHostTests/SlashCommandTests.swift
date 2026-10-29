import Testing
import PiAI
@testable import PiHost

struct SlashCommandTests {
    @Test func parsingSeparatesProseCommandsAndArguments() throws {
        #expect(try SlashCommand.parse("Discuss /new here") == nil)
        #expect(try SlashCommand.parse("/Users/example/file.swift") == nil)
        #expect(try SlashCommand.parse("//literal") == nil)
        #expect(try SlashCommand.parse("/skill:review my code") == nil)
        #expect(try SlashCommand.parse(" /NAME  中文 标题  ")?.argument == "中文 标题")
        #expect(try SlashCommand.parse("/compact preserve decisions")?.command == .compact)
        #expect(try SlashCommand.parse("/exit")?.command == .quit)
        #expect(throws: (any Error).self) { try SlashCommand.parse("/new please") }
        #expect(throws: (any Error).self) { try SlashCommand.parse("/unknown") }
        #expect(throws: (any Error).self) { try SlashCommand.parse("/") }
    }
    @Test func completionOnlyHandlesLeadingCommandToken() {
        #expect(SlashCommand.suggestions("/mo") == [.model])
        #expect(SlashCommand.suggestions("/name title").isEmpty)
        #expect(SlashCommand.suggestions("code\n/").isEmpty)
        #expect(!SlashCommand.suggestions("/").contains(.quit))
    }
    @Test func modelLookupDoesNotSilentlyPickAmbiguousRoutes() throws {
        let a = ConnectionProfile(id: "a", name: "Work", modelID: "model", api: "openai-completions", endpoint: "https://example.invalid", provider: "provider")
        var b = a; b.id = "b"; b.name = "Home"
        #expect(try SlashCommand.matchConnection("provider/model", profiles: [a]) == a)
        #expect(try SlashCommand.matchConnection("Home", profiles: [a,b]) == b)
        #expect(throws: (any Error).self) { try SlashCommand.matchConnection("model", profiles: [a,b]) }
        #expect(throws: (any Error).self) { try SlashCommand.matchConnection("missing", profiles: [a]) }
    }
}
