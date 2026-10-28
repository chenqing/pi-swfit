import Foundation
import PiAI
import Testing
@testable import PiCodingAgent

// Port of test/compaction-nested-calls.test.ts

@Suite("compaction file operations") struct CompactionNestedCallsTests {
    @Test("include files touched by nested calls recorded on tool results") func nestedCalls() {
        let result = ToolResultMessage(
            toolCallId: "codemode-1",
            toolName: "codemode",
            content: [],
            nestedCalls: NestedToolCalls(
                calls: [
                    NestedToolCallRecord(id: "codemode-1/1", name: "read", arguments: ["path": "a.ts"], status: "ok"),
                    NestedToolCallRecord(id: "codemode-1/2", name: "edit", arguments: ["path": "b.ts", "edits": []], status: "ok"),
                    NestedToolCallRecord(id: "codemode-1/3", name: "write", argumentsBytes: 40000, status: "ok"),
                ],
                complete: false
            ),
            isError: false,
            timestamp: 0
        )
        var fileOps = createFileOps()
        extractFileOpsFromMessage(.toolResult(result), &fileOps)
        let lists = computeFileLists(fileOps)
        #expect(lists.readFiles == ["a.ts"])
        #expect(lists.modifiedFiles == ["b.ts"])
    }
}
