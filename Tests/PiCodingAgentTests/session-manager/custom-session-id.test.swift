import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/session-manager/custom-session-id.test.ts

private func matchesUuidV7(_ id: String) -> Bool {
    id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
}

private func matchesSessionFileName(_ path: String, _ id: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return name.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}-\\d{2}-\\d{2}-\\d{3}Z_\(NSRegularExpression.escapedPattern(for: id))\\.jsonl$", options: .regularExpression) != nil
}

@Suite("SessionManager.newSession with custom id") struct CustomSessionIdTests {
    @Test("uses the provided id instead of generating one") func providedId() throws {
        let session = try SessionManager.inMemory()
        _ = try session.newSession(NewSessionOptions(id: "my-custom-id"))
        #expect(session.getSessionId() == "my-custom-id")
    }

    @Test("uses the provided id when creating an in-memory session") func inMemoryProvidedId() throws {
        let session = try SessionManager.inMemory(FileManager.default.currentDirectoryPath, NewSessionOptions(id: "memory-session-id"))
        #expect(session.getSessionId() == "memory-session-id")
        #expect(session.getHeader()?.id == "memory-session-id")
        #expect(session.getSessionFile() == nil)
    }

    @Test("allows alphanumeric session ids with interior punctuation") func interiorPunctuation() throws {
        let session = try SessionManager.inMemory()
        _ = try session.newSession(NewSessionOptions(id: "abc-123_def.456"))
        #expect(session.getSessionId() == "abc-123_def.456")
    }

    @Test("rejects invalid custom session ids") func rejectsInvalid() throws {
        let invalidIds = ["", "-abc", "abc-", "_abc", "abc_", ".abc", "abc.", "abc/def", "abc\\def", "abc def"]

        for id in invalidIds {
            let session = try SessionManager.inMemory()
            let message = thrownMessage { _ = try session.newSession(NewSessionOptions(id: id)) }
            #expect(message?.contains("Session id must be non-empty, contain only alphanumeric characters") == true, "id: \(id)")
        }
    }

    @Test("generates a UUIDv7 id when no id is provided") func generatesId() throws {
        let session = try SessionManager.inMemory()
        _ = try session.newSession()
        let id = session.getSessionId()
        #expect(!id.isEmpty)
        #expect(matchesUuidV7(id))
    }

    @Test("generates a UUIDv7 id when options is provided without id") func generatesIdWithOptions() throws {
        let session = try SessionManager.inMemory()
        _ = try session.newSession(NewSessionOptions(parentSession: "parent.jsonl"))
        let id = session.getSessionId()
        #expect(!id.isEmpty)
        #expect(matchesUuidV7(id))
    }

    @Test("includes the custom id in the session header") func idInHeader() throws {
        let session = try SessionManager.inMemory()
        _ = try session.newSession(NewSessionOptions(id: "header-test-id"))

        let header = try #require(session.getHeader())
        #expect(header.id == "header-test-id")
    }

    @Test("generates a UUIDv7 id when constructed without an explicit id") func constructedId() throws {
        let session = try SessionManager.inMemory()
        #expect(matchesUuidV7(session.getSessionId()))
        #expect(session.getHeader()?.id == session.getSessionId())
    }

    @Test("uses the provided id when creating a persisted session") func persistedProvidedId() throws {
        let tempDir = try makeTempDir("pi-session-manager")
        defer { removeDir(tempDir) }
        let session = try SessionManager.create(tempDir, tempDir, NewSessionOptions(id: "created-session-id"))

        #expect(session.getSessionId() == "created-session-id")
        #expect(session.getHeader()?.id == "created-session-id")
        let sessionFile = try #require(session.getSessionFile())
        #expect(sessionFile.contains("created-session-id"))
        #expect(matchesSessionFileName(sessionFile, "created-session-id"))
        #expect(!FileManager.default.fileExists(atPath: sessionFile))
    }

    @Test("generates a UUIDv7 id when creating a branched session") func branchedSessionId() throws {
        let session = try SessionManager.inMemory()
        let firstId = try session.appendMessage(AgentMessage.user(UserMessage(content: .blocks([.text(TextContent(text: "hello"))]), timestamp: dateNow())))

        try session.createBranchedSession(firstId)

        #expect(matchesUuidV7(session.getSessionId()))
        #expect(session.getHeader()?.id == session.getSessionId())
    }

    @Test("generates a UUIDv7 id when forking from another session file") func forkGeneratesId() throws {
        let tempDir = try makeTempDir("pi-session-manager")
        defer { removeDir(tempDir) }
        let sourcePath = (tempDir as NSString).appendingPathComponent("source.jsonl")
        let header: JsonValue = [
            "type": "session", "version": 3, "id": "legacy-session-id", "timestamp": .string(toISOString(dateNow())), "cwd": .string(tempDir),
        ]
        let message: JsonValue = [
            "type": "message",
            "id": "entry-1",
            "parentId": .null,
            "timestamp": .string(toISOString(dateNow())),
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": "hello"]],
                "api": "openai-responses",
                "provider": "openai",
                "model": "gpt-5.4",
                "usage": [
                    "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0],
                ],
                "stopReason": "stop",
                "timestamp": .number(Double(dateNow())),
            ],
        ]
        try "\(header.serialized())\n\(message.serialized())\n".write(toFile: sourcePath, atomically: true, encoding: .utf8)

        let forked = try SessionManager.forkFrom(sourcePath, tempDir, tempDir)
        let forkedHeader = try #require(forked.getHeader())
        #expect(matchesUuidV7(forkedHeader.id))
        #expect(forkedHeader.parentSession == sourcePath)
    }

    @Test("uses the provided id when forking from another session file") func forkProvidedId() throws {
        let tempDir = try makeTempDir("pi-session-manager")
        defer { removeDir(tempDir) }
        let sourcePath = (tempDir as NSString).appendingPathComponent("source.jsonl")
        let header: JsonValue = [
            "type": "session", "version": 3, "id": "source-session-id", "timestamp": .string(toISOString(dateNow())), "cwd": .string(tempDir),
        ]
        try "\(header.serialized())\n".write(toFile: sourcePath, atomically: true, encoding: .utf8)

        let forked = try SessionManager.forkFrom(sourcePath, tempDir, tempDir, NewSessionOptions(id: "forked-session-id"))
        let forkedHeader = try #require(forked.getHeader())
        #expect(forkedHeader.id == "forked-session-id")
        #expect(forkedHeader.parentSession == sourcePath)
        let sessionFile = try #require(forked.getSessionFile())
        #expect(sessionFile.contains("forked-session-id"))
        #expect(matchesSessionFileName(sessionFile, "forked-session-id"))
    }
}
