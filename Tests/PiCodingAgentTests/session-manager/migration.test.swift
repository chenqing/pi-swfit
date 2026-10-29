import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/session-manager/migration.test.ts

private let assistantJson: JsonValue = [
    "role": "assistant",
    "content": [["type": "text", "text": "hello"]],
    "api": "test",
    "provider": "test",
    "model": "test",
    "usage": ["input": 1, "output": 1, "cacheRead": 0, "cacheWrite": 0],
    "stopReason": "stop",
    "timestamp": 2,
]

@Suite("migrateSessionEntries") struct MigrationTests {
    @Test("should add id/parentId to v1 entries") func addsIds() throws {
        var entries: [FileEntry] = [
            FileEntry(object: ["type": "session", "id": "sess-1", "timestamp": "2025-01-01T00:00:00Z", "cwd": "/tmp"]),
            FileEntry(object: [
                "type": "message", "timestamp": "2025-01-01T00:00:01Z",
                "message": ["role": "user", "content": "hi", "timestamp": 1],
            ]),
            FileEntry(object: ["type": "message", "timestamp": "2025-01-01T00:00:02Z", "message": assistantJson]),
        ]

        migrateSessionEntries(&entries)

        // Header should have version set (v3 is current after hookMessage->custom migration)
        #expect(entries[0].sessionHeader?.version == 3)

        // Entries should have id/parentId
        let msg1 = try #require(entries[1].sessionEntry)
        let msg2 = try #require(entries[2].sessionEntry)

        #expect(msg1.id.count == 8)
        #expect(msg1.parentId == nil)

        #expect(msg2.id.count == 8)
        #expect(msg2.parentId == msg1.id)
    }

    @Test("migration reserves generated IDs before the next collision check") func reservesGeneratedIDs() throws {
        var entries = (0..<4).map { index in
            FileEntry(object: ["type": "message", "timestamp": "2025-01-01T00:00:00Z",
                               "message": ["role": "user", "content": .string("Message \(index)"), "timestamp": 1]])
        }
        migrateV1ToV2(&entries) { has in
            ["same-id", "next-id", "third-id", "last-id"].first { !has($0) }!
        }
        let messages = entries.compactMap(\.sessionEntry)
        #expect(messages.map(\.id) == ["same-id", "next-id", "third-id", "last-id"])
        #expect(messages.map(\.parentId) == [nil, "same-id", "next-id", "third-id"])
        #expect(buildSessionContext(messages).messages.count == 4)
    }

    @Test("should be idempotent (skip already migrated)") func idempotent() throws {
        var entries: [FileEntry] = [
            FileEntry(object: ["type": "session", "id": "sess-1", "version": 2, "timestamp": "2025-01-01T00:00:00Z", "cwd": "/tmp"]),
            FileEntry(object: [
                "type": "message", "id": "abc12345", "parentId": .null, "timestamp": "2025-01-01T00:00:01Z",
                "message": ["role": "user", "content": "hi", "timestamp": 1],
            ]),
            FileEntry(object: [
                "type": "message", "id": "def67890", "parentId": "abc12345", "timestamp": "2025-01-01T00:00:02Z",
                "message": assistantJson,
            ]),
        ]

        migrateSessionEntries(&entries)

        // IDs should be unchanged
        #expect(entries[1].sessionEntry?.id == "abc12345")
        #expect(entries[2].sessionEntry?.id == "def67890")
        #expect(entries[2].sessionEntry?.parentId == "abc12345")
    }
}
