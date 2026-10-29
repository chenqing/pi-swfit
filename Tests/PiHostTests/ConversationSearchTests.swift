import Testing
@testable import PiHost

struct ConversationSearchTests {
    @Test func bodyMatchesKeepUnicodeContextAndIgnoreCase() {
        let body = String(repeating: "前面的中文 👩🏽‍💻 ", count: 20) + "PRINT(greeting)\n下一行" + String(repeating: " trailing", count: 30)
        let snippet = ConversationSearch.excerpt(in: body, matching: "print(GREETING)")
        #expect(snippet?.contains("PRINT(greeting) 下一行") == true)
        #expect(snippet?.hasPrefix("…") == true)
        #expect(snippet?.hasSuffix("…") == true)
        #expect(ConversationSearch.excerpt(in: body, matching: "missing") == nil)
        #expect(ConversationSearch.excerpt(in: body, matching: " \n") == nil)
    }
    @Test func shortAndLongMatchesRemainIntact() {
        #expect(ConversationSearch.excerpt(in: "Café 中文", matching: "cafe") == "Café 中文")
        let long = String(repeating: "长", count: 150)
        #expect(ConversationSearch.excerpt(in: long, matching: long) == long)
    }
}
