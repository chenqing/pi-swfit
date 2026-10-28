import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/session-manager/load-entries.test.ts

private func matchesUuidV7(_ id: String) -> Bool {
    id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
}

private func userMessage(_ text: String) -> AgentMessage {
    .user(UserMessage(content: .blocks([.text(TextContent(text: text))]), timestamp: dateNow()))
}

private func storedEntries(_ build: (SessionManager) throws -> Void) throws -> [SessionEntry] {
    let source = try SessionManager.inMemory("/project")
    try build(source)
    return source.getEntries()
}

private func fileEntries(_ entries: [SessionEntry]) -> [FileEntry] { entries.map { .entry($0) } }

@Suite("SessionManager.inMemory with preloaded entries") struct LoadEntriesTests {
    @Test("adopts entries verbatim") func adoptsVerbatim() throws {
        let entries = try storedEntries { source in
            _ = try source.appendMessage(userMessage("hello"))
            _ = try source.appendModelChange("anthropic", "claude-opus-4-5")
            _ = try source.appendMessage(userMessage("again"))
        }

        let session = try SessionManager.inMemory("/project", nil, fileEntries(entries))

        #expect(session.getEntries().map(\.json) == entries.map(\.json))
    }

    @Test("keeps the loaded leaf so appends continue the conversation") func keepsLeaf() throws {
        let entries = try storedEntries { source in
            _ = try source.appendMessage(userMessage("hello"))
            _ = try source.appendMessage(userMessage("again"))
        }
        let lastId = entries[entries.count - 1].id

        let session = try SessionManager.inMemory("/project", nil, fileEntries(entries))
        let appendedId = try session.appendMessage(userMessage("continued"))

        #expect(session.getLeafId() == appendedId)
        #expect(session.getEntry(appendedId)?.parentId == lastId)
    }

    @Test("never mints an id that collides with a loaded entry") func noCollisions() throws {
        let entries = try storedEntries { source in
            for i in 0..<50 { _ = try source.appendMessage(userMessage("message \(i)")) }
        }

        let session = try SessionManager.inMemory("/project", nil, fileEntries(entries))
        let appendedId = try session.appendMessage(userMessage("continued"))

        #expect(!entries.contains { $0.id == appendedId })
    }

    @Test("rebuilds the branch structure rather than a flat chain") func rebuildsBranches() throws {
        let entries = try storedEntries { source in
            let firstId = try source.appendMessage(userMessage("hello"))
            _ = try source.appendMessage(userMessage("abandoned"))
            try source.branch(firstId)
            _ = try source.appendMessage(userMessage("kept"))
        }

        let session = try SessionManager.inMemory("/project", nil, fileEntries(entries))
        let roots = session.getTree()

        #expect(roots.count == 1)
        #expect(roots[0].children.count == 2)
    }

    @Test("rebuilds labels") func rebuildsLabels() throws {
        var labelledId = ""
        let entries = try storedEntries { source in
            labelledId = try source.appendMessage(userMessage("hello"))
            _ = try source.appendLabelChange(labelledId, "checkpoint")
        }

        let session = try SessionManager.inMemory("/project", nil, fileEntries(entries))

        #expect(session.getLabel(labelledId) == "checkpoint")
    }

    @Test("resolves a compaction against the entry it was written against") func resolvesCompaction() throws {
        var keptId = ""
        let entries = try storedEntries { source in
            _ = try source.appendMessage(userMessage("dropped"))
            keptId = try source.appendMessage(userMessage("kept"))
            _ = try source.appendCompaction("summary so far", keptId, 1000)
        }

        let session = try SessionManager.inMemory("/project", nil, fileEntries(entries))
        let context = session.buildContextEntries()

        #expect(context.contains { $0.id == keptId })
    }

    @Test("creates a header from the options when the entries carry none") func headerFromOptions() throws {
        let entries = try storedEntries { _ = try $0.appendMessage(userMessage("hello")) }

        let session = try SessionManager.inMemory("/project", NewSessionOptions(id: "restored-session"), fileEntries(entries))

        #expect(session.getSessionId() == "restored-session")
        #expect(session.getHeader()?.id == "restored-session")
        #expect(session.getHeader()?.cwd == "/project")
    }

    @Test("generates a session id when the options carry none") func generatesId() throws {
        let entries = try storedEntries { _ = try $0.appendMessage(userMessage("hello")) }

        let session = try SessionManager.inMemory("/project", nil, fileEntries(entries))

        #expect(matchesUuidV7(session.getSessionId()))
        #expect(session.getHeader()?.id == session.getSessionId())
    }

    @Test("stays off the filesystem") func staysOffFilesystem() throws {
        let entries = try storedEntries { _ = try $0.appendMessage(userMessage("hello")) }

        let session = try SessionManager.inMemory("/project", nil, fileEntries(entries))
        _ = try session.appendMessage(userMessage("continued"))

        #expect(session.getSessionFile() == nil)
        #expect(session.isPersisted() == false)
    }

    @Test("starts an empty session when the entries are empty") func emptyEntries() throws {
        let session = try SessionManager.inMemory("/project", NewSessionOptions(id: "empty-session"), [])

        #expect(session.getSessionId() == "empty-session")
        #expect(session.getEntries().isEmpty)
        #expect(session.getLeafId() == nil)
    }

    @Test("takes the session identity from a header among the entries") func identityFromHeader() throws {
        let body = try storedEntries { _ = try $0.appendMessage(userMessage("hello")) }
        let entries: [FileEntry] = [
            .header(SessionHeader(version: 3, id: "stored-session", timestamp: "2026-01-01T00:00:00Z", cwd: "/stored")),
        ] + fileEntries(body)

        let session = try SessionManager.inMemory("/project", NewSessionOptions(id: "ignored"), entries)

        #expect(session.getSessionId() == "stored-session")
        #expect(session.getHeader()?.cwd == "/stored")
    }

    private static let hookMessageEntry: JsonObject = [
        "type": "message",
        "id": "abc12345",
        "parentId": .null,
        "timestamp": "2026-01-01T00:00:01Z",
        "message": ["role": "hookMessage", "content": "from a hook", "timestamp": 1],
    ]

    @Test("migrates entries restored with an older header") func migratesOlderHeader() throws {
        let entries: [FileEntry] = [
            .header(SessionHeader(version: 2, id: "v2-session", timestamp: "2026-01-01T00:00:00Z", cwd: "/project")),
            FileEntry(object: Self.hookMessageEntry),
        ]

        let session = try SessionManager.inMemory("/project", nil, entries)
        let restored = try #require(session.getEntries()[0].messageEntry)

        #expect(session.getHeader()?.version == 3)
        #expect(restored.message.role == "custom")
        #expect(restored.id == "abc12345")
    }

    @Test("adopts headerless entries as current-version without migrating them") func headerlessNotMigrated() throws {
        let entries: [FileEntry] = [FileEntry(object: Self.hookMessageEntry)]

        let session = try SessionManager.inMemory("/project", nil, entries)
        let restored = try #require(session.getEntries()[0].messageEntry)

        #expect(restored.message.role == "hookMessage")
    }
}
