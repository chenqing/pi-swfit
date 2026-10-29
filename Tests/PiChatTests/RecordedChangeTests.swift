import Testing
@testable import PiChat

@Suite struct RecordedChangeTests {
    @Test func countsHunkLinesWithoutCountingHeaders() {
        var tool = ChatToolCall(id: "change", name: "edit", arguments: #"{"path":"Sources/main.swift"}"#)
        tool.diff = "--- Sources/main.swift\n+++ Sources/main.swift\n@@ -1,2 +1,2 @@\n-old\n+++literal\n context\n@@ -5 +5 @@\n---literal\n+new\n"
        let result = RecordedChange(tool: tool)
        #expect(result?.path == "Sources/main.swift")
        #expect(result?.added == 2 && result?.removed == 2)
        #expect(result?.diff == tool.diff)
        tool.diff = nil
        #expect(RecordedChange(tool: tool) == nil)
    }
}
