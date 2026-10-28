import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/session-manager/tree-traversal.test.ts

@Suite("SessionManager append and tree traversal") struct TreeTraversalTests {
    // MARK: append operations

    @Test("appendMessage creates entry with correct parentId chain") func appendMessageChain() throws {
        let session = try SessionManager.inMemory()

        let id1 = try session.appendMessage(userMsg("first"))
        let id2 = try session.appendMessage(assistantMsg("second"))
        let id3 = try session.appendMessage(userMsg("third"))

        let entries = session.getEntries()
        #expect(entries.count == 3)

        #expect(entries[0].id == id1)
        #expect(entries[0].parentId == nil)
        #expect(entries[0].type == "message")

        #expect(entries[1].id == id2)
        #expect(entries[1].parentId == id1)

        #expect(entries[2].id == id3)
        #expect(entries[2].parentId == id2)
    }

    @Test("appendThinkingLevelChange integrates into tree") func thinkingLevelChange() throws {
        let session = try SessionManager.inMemory()

        let msgId = try session.appendMessage(userMsg("hello"))
        let thinkingId = try session.appendThinkingLevelChange("high")
        _ = try session.appendMessage(assistantMsg("response"))

        let entries = session.getEntries()
        #expect(entries.count == 3)

        let thinkingEntry = try #require(entries.first { $0.type == "thinking_level_change" })
        #expect(thinkingEntry.id == thinkingId)
        #expect(thinkingEntry.parentId == msgId)

        #expect(entries[2].parentId == thinkingId)
    }

    @Test("appendModelChange integrates into tree") func modelChange() throws {
        let session = try SessionManager.inMemory()

        let msgId = try session.appendMessage(userMsg("hello"))
        let modelId = try session.appendModelChange("openai", "gpt-4")
        _ = try session.appendMessage(assistantMsg("response"))

        let entries = session.getEntries()
        let modelEntry = try #require(entries.first { $0.type == "model_change" })
        #expect(modelEntry.id == modelId)
        #expect(modelEntry.parentId == msgId)
        if case .modelChange(let change) = modelEntry {
            #expect(change.provider == "openai")
            #expect(change.modelId == "gpt-4")
        }

        #expect(entries[2].parentId == modelId)
    }

    @Test("appendCompaction integrates into tree") func compaction() throws {
        let session = try SessionManager.inMemory()

        let id1 = try session.appendMessage(userMsg("1"))
        let id2 = try session.appendMessage(assistantMsg("2"))
        let usage = sampleUsage
        let compactionId = try session.appendCompaction("summary", id1, 1000, nil, false, usage)
        _ = try session.appendMessage(userMsg("3"))

        let entries = session.getEntries()
        let compactionEntry = try #require(entries.first { $0.type == "compaction" })
        #expect(compactionEntry.id == compactionId)
        #expect(compactionEntry.parentId == id2)
        if let compaction = compactionEntry.compactionEntry {
            #expect(compaction.summary == "summary")
            #expect(compaction.firstKeptEntryId == id1)
            #expect(compaction.tokensBefore == 1000)
            #expect(compaction.usage == usage)
        }

        #expect(entries[3].parentId == compactionId)
    }

    @Test("appendCustomEntry integrates into tree") func customEntry() throws {
        let session = try SessionManager.inMemory()

        let msgId = try session.appendMessage(userMsg("hello"))
        let customId = try session.appendCustomEntry("my_data", ["key": "value"])
        _ = try session.appendMessage(assistantMsg("response"))

        let entries = session.getEntries()
        guard case .custom(let customEntry)? = entries.first(where: { $0.type == "custom" }) else {
            Issue.record("custom entry missing")
            return
        }
        #expect(customEntry.id == customId)
        #expect(customEntry.parentId == msgId)
        #expect(customEntry.customType == "my_data")
        #expect(customEntry.data == ["key": "value"])

        #expect(entries[2].parentId == customId)
    }

    @Test("leaf pointer advances after each append") func leafAdvances() throws {
        let session = try SessionManager.inMemory()

        #expect(session.getLeafId() == nil)

        let id1 = try session.appendMessage(userMsg("1"))
        #expect(session.getLeafId() == id1)

        let id2 = try session.appendMessage(assistantMsg("2"))
        #expect(session.getLeafId() == id2)

        let id3 = try session.appendThinkingLevelChange("high")
        #expect(session.getLeafId() == id3)
    }

    // MARK: getPath

    @Test("returns empty array for empty session") func emptyPath() throws {
        let session = try SessionManager.inMemory()
        #expect(session.getBranch().isEmpty)
    }

    @Test("returns single entry path") func singleEntryPath() throws {
        let session = try SessionManager.inMemory()
        let id = try session.appendMessage(userMsg("hello"))

        let path = session.getBranch()
        #expect(path.count == 1)
        #expect(path[0].id == id)
    }

    @Test("returns full path from root to leaf") func fullPath() throws {
        let session = try SessionManager.inMemory()

        let id1 = try session.appendMessage(userMsg("1"))
        let id2 = try session.appendMessage(assistantMsg("2"))
        let id3 = try session.appendThinkingLevelChange("high")
        let id4 = try session.appendMessage(userMsg("3"))

        let path = session.getBranch()
        #expect(path.count == 4)
        #expect(path.map(\.id) == [id1, id2, id3, id4])
    }

    @Test("returns path from specified entry to root") func pathFromEntry() throws {
        let session = try SessionManager.inMemory()

        let id1 = try session.appendMessage(userMsg("1"))
        let id2 = try session.appendMessage(assistantMsg("2"))
        _ = try session.appendMessage(userMsg("3"))
        _ = try session.appendMessage(assistantMsg("4"))

        let path = session.getBranch(id2)
        #expect(path.count == 2)
        #expect(path.map(\.id) == [id1, id2])
    }

    // MARK: getTree

    @Test("getTree returns empty array for empty session") func emptyTree() throws {
        let session = try SessionManager.inMemory()
        #expect(session.getTree().isEmpty)
    }

    @Test("returns single root for linear session") func linearTree() throws {
        let session = try SessionManager.inMemory()

        let id1 = try session.appendMessage(userMsg("1"))
        let id2 = try session.appendMessage(assistantMsg("2"))
        let id3 = try session.appendMessage(userMsg("3"))

        let tree = session.getTree()
        #expect(tree.count == 1)

        let root = tree[0]
        #expect(root.entry.id == id1)
        #expect(root.children.count == 1)
        #expect(root.children[0].entry.id == id2)
        #expect(root.children[0].children.count == 1)
        #expect(root.children[0].children[0].entry.id == id3)
        #expect(root.children[0].children[0].children.isEmpty)
    }

    @Test("returns tree with branches after branch") func branchedTree() throws {
        let session = try SessionManager.inMemory()

        // Build: 1 -> 2 -> 3
        let id1 = try session.appendMessage(userMsg("1"))
        let id2 = try session.appendMessage(assistantMsg("2"))
        let id3 = try session.appendMessage(userMsg("3"))

        // Branch from id2, add new path: 2 -> 4
        try session.branch(id2)
        let id4 = try session.appendMessage(userMsg("4-branch"))

        let tree = session.getTree()
        #expect(tree.count == 1)

        let root = tree[0]
        #expect(root.entry.id == id1)
        #expect(root.children.count == 1)

        let node2 = root.children[0]
        #expect(node2.entry.id == id2)
        #expect(node2.children.count == 2) // id3 and id4 are siblings

        #expect(node2.children.map(\.entry.id).sorted() == [id3, id4].sorted())
    }

    @Test("handles multiple branches at same point") func multipleBranches() throws {
        let session = try SessionManager.inMemory()

        _ = try session.appendMessage(userMsg("root"))
        let id2 = try session.appendMessage(assistantMsg("response"))

        // Branch A
        try session.branch(id2)
        let idA = try session.appendMessage(userMsg("branch-A"))

        // Branch B
        try session.branch(id2)
        let idB = try session.appendMessage(userMsg("branch-B"))

        // Branch C
        try session.branch(id2)
        let idC = try session.appendMessage(userMsg("branch-C"))

        let tree = session.getTree()
        let node2 = tree[0].children[0]
        #expect(node2.entry.id == id2)
        #expect(node2.children.count == 3)

        #expect(node2.children.map(\.entry.id).sorted() == [idA, idB, idC].sorted())
    }

    @Test("handles deep branching") func deepBranching() throws {
        let session = try SessionManager.inMemory()

        // Main path: 1 -> 2 -> 3 -> 4
        _ = try session.appendMessage(userMsg("1"))
        let id2 = try session.appendMessage(assistantMsg("2"))
        let id3 = try session.appendMessage(userMsg("3"))
        _ = try session.appendMessage(assistantMsg("4"))

        // Branch from 2: 2 -> 5 -> 6
        try session.branch(id2)
        let id5 = try session.appendMessage(userMsg("5"))
        _ = try session.appendMessage(assistantMsg("6"))

        // Branch from 5: 5 -> 7
        try session.branch(id5)
        _ = try session.appendMessage(userMsg("7"))

        let tree = session.getTree()

        // Verify structure
        let node2 = tree[0].children[0]
        #expect(node2.children.count == 2) // id3 and id5

        let node5 = try #require(node2.children.first { $0.entry.id == id5 })
        #expect(node5.children.count == 2) // id6 and id7

        let node3 = try #require(node2.children.first { $0.entry.id == id3 })
        #expect(node3.children.count == 1) // id4
    }

    // MARK: branch

    @Test("moves leaf pointer to specified entry") func branchMovesLeaf() throws {
        let session = try SessionManager.inMemory()

        let id1 = try session.appendMessage(userMsg("1"))
        _ = try session.appendMessage(assistantMsg("2"))
        let id3 = try session.appendMessage(userMsg("3"))

        #expect(session.getLeafId() == id3)

        try session.branch(id1)
        #expect(session.getLeafId() == id1)
    }

    @Test("branch throws for non-existent entry") func branchThrows() throws {
        let session = try SessionManager.inMemory()
        _ = try session.appendMessage(userMsg("hello"))

        #expect(thrownMessage { try session.branch("nonexistent") }?.contains("Entry nonexistent not found") == true)
    }

    @Test("new appends become children of branch point") func appendsAfterBranch() throws {
        let session = try SessionManager.inMemory()

        let id1 = try session.appendMessage(userMsg("1"))
        _ = try session.appendMessage(assistantMsg("2"))

        try session.branch(id1)
        let id3 = try session.appendMessage(userMsg("branched"))

        let branchedEntry = try #require(session.getEntries().first { $0.id == id3 })
        #expect(branchedEntry.parentId == id1) // sibling of id2
    }

    // MARK: branchWithSummary

    @Test("inserts branch summary with the source and destination and advances leaf") func branchWithSummary() throws {
        let session = try SessionManager.inMemory()

        let id1 = try session.appendMessage(userMsg("1"))
        _ = try session.appendMessage(assistantMsg("2"))
        let id3 = try session.appendMessage(userMsg("3"))

        let usage = sampleUsage
        let summaryId = try session.branchWithSummary(id1, "Summary of abandoned work", nil, false, usage)

        #expect(session.getLeafId() == summaryId)

        let summaryEntry = try #require(session.getEntries().first { $0.type == "branch_summary" })
        #expect(summaryEntry.parentId == id1)
        if let summary = summaryEntry.branchSummaryEntry {
            #expect(summary.fromId == id3)
            #expect(summary.summary == "Summary of abandoned work")
            #expect(summary.usage == usage)
        }
    }

    @Test("branchWithSummary throws for non-existent entry") func branchWithSummaryThrows() throws {
        let session = try SessionManager.inMemory()
        _ = try session.appendMessage(userMsg("hello"))

        #expect(thrownMessage { try session.branchWithSummary("nonexistent", "summary") }?.contains("Entry nonexistent not found") == true)
    }

    // MARK: getLeafEntry

    @Test("getLeafEntry returns undefined for empty session") func leafEntryEmpty() throws {
        let session = try SessionManager.inMemory()
        #expect(session.getLeafEntry() == nil)
    }

    @Test("returns current leaf entry") func currentLeafEntry() throws {
        let session = try SessionManager.inMemory()

        _ = try session.appendMessage(userMsg("1"))
        let id2 = try session.appendMessage(assistantMsg("2"))

        let leaf = try #require(session.getLeafEntry())
        #expect(leaf.id == id2)
    }

    // MARK: getEntry

    @Test("getEntry returns undefined for non-existent id") func getEntryMissing() throws {
        let session = try SessionManager.inMemory()
        #expect(session.getEntry("nonexistent") == nil)
    }

    @Test("returns entry by id") func getEntryById() throws {
        let session = try SessionManager.inMemory()

        let id1 = try session.appendMessage(userMsg("first"))
        let id2 = try session.appendMessage(assistantMsg("second"))

        let entry1 = try #require(session.getEntry(id1))
        #expect(entry1.type == "message")
        #expect(entry1.message.flatMap(contentString) == "first")

        let entry2 = try #require(session.getEntry(id2))
        #expect(entry2.message.flatMap(firstText) == "second")
    }

    // MARK: buildSessionContext with branches

    @Test("returns messages from current branch only") func currentBranchOnly() throws {
        let session = try SessionManager.inMemory()

        // Main: 1 -> 2 -> 3
        _ = try session.appendMessage(userMsg("msg1"))
        let id2 = try session.appendMessage(assistantMsg("msg2"))
        _ = try session.appendMessage(userMsg("msg3"))

        // Branch from 2: 2 -> 4
        try session.branch(id2)
        _ = try session.appendMessage(assistantMsg("msg4-branch"))

        let ctx = session.buildSessionContext()
        #expect(ctx.messages.count == 3) // msg1, msg2, msg4-branch (not msg3)

        #expect(contentString(ctx.messages[0]) == "msg1")
        #expect(firstText(ctx.messages[1]) == "msg2")
        #expect(firstText(ctx.messages[2]) == "msg4-branch")
    }
}

@Suite("createBranchedSession") struct CreateBranchedSessionTests {
    @Test("throws for non-existent entry") func throwsForMissing() throws {
        let session = try SessionManager.inMemory()
        _ = try session.appendMessage(userMsg("hello"))

        #expect(thrownMessage { try session.createBranchedSession("nonexistent") }?.contains("Entry nonexistent not found") == true)
    }

    @Test("creates new session with path to specified leaf (in-memory)") func inMemoryBranch() throws {
        let session = try SessionManager.inMemory()

        // Build: 1 -> 2 -> 3 -> 4
        let id1 = try session.appendMessage(userMsg("1"))
        let id2 = try session.appendMessage(assistantMsg("2"))
        let id3 = try session.appendMessage(userMsg("3"))
        _ = try session.appendMessage(assistantMsg("4"))

        // Branch from 3: 3 -> 5
        try session.branch(id3)
        _ = try session.appendMessage(userMsg("5"))

        // Create branched session from id2 (should only have 1 -> 2)
        let result = try session.createBranchedSession(id2)
        #expect(result == nil) // in-memory returns null

        // Session should now only have entries 1 and 2
        let entries = session.getEntries()
        #expect(entries.count == 2)
        #expect(entries[0].id == id1)
        #expect(entries[1].id == id2)
    }

    @Test("extracts correct path from branched tree") func extractsPath() throws {
        let session = try SessionManager.inMemory()

        // Build: 1 -> 2 -> 3
        let id1 = try session.appendMessage(userMsg("1"))
        let id2 = try session.appendMessage(assistantMsg("2"))
        _ = try session.appendMessage(userMsg("3"))

        // Branch from 2: 2 -> 4 -> 5
        try session.branch(id2)
        let id4 = try session.appendMessage(userMsg("4"))
        let id5 = try session.appendMessage(assistantMsg("5"))

        // Create branched session from id5 (should have 1 -> 2 -> 4 -> 5)
        try session.createBranchedSession(id5)

        #expect(session.getEntries().map(\.id) == [id1, id2, id4, id5])
    }

    @Test("does not duplicate entries when forking from before the first user message") func noDuplicateEntries() throws {
        let tempDir = try makeTempDir("session-fork-dedup")
        defer { removeDir(tempDir) }

        // Create a persisted session with a couple of turns
        let session = try SessionManager.create(tempDir, tempDir)
        let modelChangeId = try session.appendModelChange("anthropic", "claude-sonnet-4-5")
        _ = try session.appendMessage(userMsg("first question"))
        _ = try session.appendMessage(assistantMsg("first answer"))

        // Fork from a setup entry (no user or assistant message in the branched path)
        let newFile = try #require(try session.createBranchedSession(modelChangeId))

        // Nothing to save yet, so the file is created later by the first user message
        #expect(!FileManager.default.fileExists(atPath: newFile))

        _ = try session.appendMessage(userMsg("new question"))
        #expect(FileManager.default.fileExists(atPath: newFile))

        // Simulate extension adding entry before assistant (like preset on turn_start)
        _ = try session.appendCustomEntry("preset-state", ["name": "plan"])
        _ = try session.appendMessage(assistantMsg("new answer"))

        // Exactly one header and each entry written once
        #expect(try readSessionFileRoles(newFile) == ["session", "model_change", "user", "custom", "assistant"])
    }

    @Test("preserves tool and summary usage across a file-backed reload") func usageRoundtrip() throws {
        let tempDir = try makeTempDir("session-usage-roundtrip")
        defer { removeDir(tempDir) }

        let session = try SessionManager.create(tempDir, tempDir)
        let rootId = try session.appendMessage(userMsg("question"))
        _ = try session.appendMessage(assistantMsg("answer"))
        let usage = sampleUsage
        _ = try session.appendMessage(AgentMessage.toolResult(ToolResultMessage(
            toolCallId: "call-1",
            toolName: "nested-model",
            content: [.text(TextContent(text: "result"))],
            usage: usage,
            isError: false,
            timestamp: dateNow()
        )))
        _ = try session.appendCompaction("summary", rootId, 100, nil, false, usage)
        _ = try session.branchWithSummary(rootId, "branch summary", nil, false, usage)

        let file = try #require(session.getSessionFile())
        let reopened = try SessionManager.open(file, tempDir)
        let entries = reopened.getEntries()
        #expect(entries.contains { $0.compactionEntry?.usage == usage })
        #expect(entries.contains { $0.branchSummaryEntry?.usage == usage })
        #expect(entries.contains { entry in
            if case .toolResult(let result)? = entry.message { return result.usage == usage }
            return false
        })
    }

    @Test("writes file immediately when forking at a user message") func forkAtUserMessage() throws {
        let tempDir = try makeTempDir("session-fork-with-user")
        defer { removeDir(tempDir) }

        let session = try SessionManager.create(tempDir, tempDir)
        let id1 = try session.appendMessage(userMsg("first question"))
        _ = try session.appendMessage(assistantMsg("first answer"))

        let newFile = try #require(try session.createBranchedSession(id1))
        #expect(FileManager.default.fileExists(atPath: newFile))

        _ = try session.appendMessage(assistantMsg("new answer"))
        #expect(try readSessionFileRoles(newFile) == ["session", "user", "assistant"])
    }
}
