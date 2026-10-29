import Testing
@testable import PiChat

struct RecordedDiffTests {
    @Test func tracksBothSidesAcrossHunksAndMetadata() {
        let diff = RecordedDiff("--- a\n+++ b\n@@ -3,2 +8,2 @@\n context\n-old\n+++literal\n\\ No newline at end of file\n@@ -20,0 +30,1 @@\n+new")
        #expect(diff.hunks == [2, 7])
        #expect(diff.lines[3].oldNumber == 3 && diff.lines[3].newNumber == 8)
        #expect(diff.lines[4].oldNumber == 4 && diff.lines[4].newNumber == nil)
        #expect(diff.lines[5].oldNumber == nil && diff.lines[5].newNumber == 9)
        #expect(diff.lines[5].text == "+++literal")
        #expect(diff.lines[6].kind == .metadata && diff.lines[6].newNumber == nil)
        #expect(diff.lines[8].newNumber == 30)
    }
    @Test func newFileResetsHunkStateAndZeroLengthRangesAreValid() {
        let diff = RecordedDiff("@@ -0,0 +1 @@\n+first\ndiff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -2 +5 @@\n-last\n+next")
        #expect(diff.lines[1].newNumber == 1)
        #expect(diff.lines[3].kind == .metadata && diff.lines[4].kind == .metadata)
        #expect(diff.lines[6].oldNumber == 2 && diff.lines[7].newNumber == 5)
    }
    @Test func toolSummariesStayActionsAndKeepRawArguments() {
        let args = #"{"path":"/tmp/project/Sources/main.swift"}"#
        let tool = ChatToolCall(id: "one", name: "edit", arguments: args, state: .failed)
        #expect(tool.summary == "Edit main.swift")
        #expect(tool.arguments == args)
        let command = ChatToolCall(id: "two", name: "bash", arguments: #"{"command":"swift test\necho done"}"#)
        #expect(command.summary == "Run swift test")
        #expect(ChatToolCall(id: "three", name: "custom", arguments: "unfinished").summary == "custom")
    }
}
