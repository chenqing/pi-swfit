import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/session-manager/file-operations.test.ts

private let HEADER_SCAN_LIMIT_BYTES = 1024 * 1024

private func join(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }

private func write(_ file: String, _ content: String) throws {
    try content.write(toFile: file, atomically: false, encoding: .utf8)
}

private func read(_ file: String) throws -> String {
    try String(contentsOfFile: file, encoding: .utf8)
}

/// `await new Promise((r) => setTimeout(r, 10))`, long enough for distinct file mtimes.
private func pause() async throws {
    try await Task.sleep(nanoseconds: 20_000_000)
}

private func writeSessionHeader(_ file: String, _ cwd: String, _ id: String, _ prefix: String = "") throws {
    let header: JsonValue = ["type": "session", "version": 3, "id": .string(id), "timestamp": "2025-01-01T00:00:00Z", "cwd": .string(cwd)]
    try write(file, "\(prefix)\(header.serialized())\n")
}

@Suite("loadEntriesFromFile") struct LoadEntriesFromFileTests {
    @Test("returns empty array for non-existent file") func nonExistent() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        #expect(loadEntriesFromFile(join(tempDir, "nonexistent.jsonl")).isEmpty)
    }

    @Test("returns empty array for empty file") func emptyFile() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "empty.jsonl")
        try write(file, "")
        #expect(loadEntriesFromFile(file).isEmpty)
    }

    @Test("returns empty array for file without valid session header") func noHeader() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "no-header.jsonl")
        try write(file, "{\"type\":\"message\",\"id\":\"1\"}\n")
        #expect(loadEntriesFromFile(file).isEmpty)
    }

    @Test("returns empty array for malformed JSON") func malformed() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "malformed.jsonl")
        try write(file, "not json\n")
        #expect(loadEntriesFromFile(file).isEmpty)
    }

    @Test("loads valid session file") func validFile() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "valid.jsonl")
        try write(
            file,
            "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n"
                + "{\"type\":\"message\",\"id\":\"1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n"
        )
        let entries = loadEntriesFromFile(file)
        #expect(entries.count == 2)
        #expect(entries[0].type == "session")
        #expect(entries[1].type == "message")
    }

    @Test("skips malformed lines but keeps valid ones") func skipsMalformedLines() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "mixed.jsonl")
        try write(
            file,
            "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n"
                + "not valid json\n"
                + "{\"type\":\"message\",\"id\":\"1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n"
        )
        #expect(loadEntriesFromFile(file).count == 2)
    }

    @Test("adds a newline after an unterminated valid record") func unterminatedValid() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "unterminated.jsonl")
        let content = "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n"
            + "{\"type\":\"message\",\"id\":\"1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}"
        try write(file, content)

        #expect(loadEntriesFromFile(file).count == 2)
        #expect(try read(file) == "\(content)\n")
    }

    @Test("adds a newline after an unterminated malformed final fragment") func unterminatedMalformed() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "malformed-tail.jsonl")
        let content = "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n" + "{\"type\":\"message\""
        try write(file, content)

        #expect(loadEntriesFromFile(file).count == 1)
        #expect(try read(file) == "\(content)\n")
    }

    @Test("does not modify an unterminated non-session file") func unterminatedNonSession() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "invalid.jsonl")
        let content = "{\"type\":\"message\",\"id\":\"1\"}"
        try write(file, content)

        #expect(loadEntriesFromFile(file).isEmpty)
        #expect(try read(file) == content)
    }

    @Test("reads cwd from a session with %s", arguments: [
        ("leading blank lines", "\n  \n", "leading-blank"),
        ("leading malformed lines", "not json\n{broken json\n", "leading-malformed"),
        ("a multi-buffer header", "", String(repeating: "a", count: 8192)),
    ])
    func readsCwd(_ description: String, _ prefix: String, _ sessionId: String) throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "header.jsonl")
        let storedCwd = join(tempDir, "stored-project")
        try writeSessionHeader(file, storedCwd, sessionId, prefix)

        let sessionManager = try SessionManager.open(file, tempDir)
        #expect(sessionManager.getSessionId() == sessionId)
        #expect(sessionManager.getCwd() == storedCwd)
    }

    @Test("opens compatible sessions beyond the discovery scan limit") func beyondScanLimit() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let storedCwd = join(tempDir, "stored-project")
        let overrideCwd = join(tempDir, "override-project")
        let cases = [
            (name: "large-header", id: String(repeating: "a", count: HEADER_SCAN_LIMIT_BYTES + 1), prefix: ""),
            (name: "large-prefix", id: "large-prefix", prefix: "\(String(repeating: "x", count: HEADER_SCAN_LIMIT_BYTES + 1))\n"),
        ]

        for (name, id, prefix) in cases {
            let file = join(tempDir, "\(name).jsonl")
            try writeSessionHeader(file, storedCwd, id, prefix)
            for cwdOverride in [nil, overrideCwd] {
                let sessionManager = try SessionManager.open(file, tempDir, cwdOverride)
                #expect(sessionManager.getSessionId() == id)
                #expect(sessionManager.getCwd() == (cwdOverride ?? storedCwd))
            }
        }
    }

    // Not ported: "opens session files larger than Node's max string length" (writes a >512 MB sparse file;
    // the limit is specific to Node strings).
}

@Suite("findMostRecentSession") struct FindMostRecentSessionTests {
    @Test("returns null for empty directory") func emptyDirectory() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        #expect(findMostRecentSession(tempDir) == nil)
    }

    @Test("returns null for non-existent directory") func nonExistentDirectory() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        #expect(findMostRecentSession(join(tempDir, "nonexistent")) == nil)
    }

    @Test("ignores non-jsonl files") func ignoresNonJsonl() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        try write(join(tempDir, "file.txt"), "hello")
        try write(join(tempDir, "file.json"), "{}")
        #expect(findMostRecentSession(tempDir) == nil)
    }

    @Test("ignores jsonl files without valid session header") func ignoresInvalidJsonl() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        try write(join(tempDir, "invalid.jsonl"), "{\"type\":\"message\"}\n")
        #expect(findMostRecentSession(tempDir) == nil)
    }

    @Test("returns single valid session file") func singleValid() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file = join(tempDir, "session.jsonl")
        try write(file, "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n")
        #expect(findMostRecentSession(tempDir) == file)
    }

    @Test("returns most recently modified session") func mostRecent() async throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let file1 = join(tempDir, "older.jsonl")
        let file2 = join(tempDir, "newer.jsonl")

        try write(file1, "{\"type\":\"session\",\"id\":\"old\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n")
        // Small delay to ensure different mtime
        try await pause()
        try write(file2, "{\"type\":\"session\",\"id\":\"new\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n")

        #expect(findMostRecentSession(tempDir) == file2)
    }

    @Test("skips invalid files and returns valid one") func skipsInvalid() async throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let invalid = join(tempDir, "invalid.jsonl")
        let valid = join(tempDir, "valid.jsonl")

        try write(invalid, "{\"type\":\"not-session\"}\n")
        try await pause()
        try write(valid, "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n")

        #expect(findMostRecentSession(tempDir) == valid)
    }

    @Test("skips oversized corrupt files and returns a valid session") func skipsOversized() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let invalid = join(tempDir, "oversized.jsonl")
        let valid = join(tempDir, "valid.jsonl")
        try write(invalid, String(repeating: "x", count: HEADER_SCAN_LIMIT_BYTES + 1))
        try write(valid, "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n")

        #expect(findMostRecentSession(tempDir) == valid)
    }

    @Test("filters most recent session by cwd") func filtersByCwd() async throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let projectA = join(tempDir, "project-a")
        let projectB = join(tempDir, "project-b")
        let fileA = join(tempDir, "a.jsonl")
        let fileB = join(tempDir, "b.jsonl")

        let headerA: JsonValue = ["type": "session", "id": "a", "timestamp": "2025-01-01T00:00:00Z", "cwd": .string(projectA)]
        try write(fileA, "\(headerA.serialized())\n")
        try await pause()
        let headerB: JsonValue = ["type": "session", "id": "b", "timestamp": "2025-01-01T00:00:00Z", "cwd": .string(projectB)]
        try write(fileB, "\(headerB.serialized())\n")

        #expect(findMostRecentSession(tempDir, projectA) == fileA)
        #expect(findMostRecentSession(tempDir, projectB) == fileB)
    }
}

@Suite("SessionManager custom flat session directory") struct FlatSessionDirectoryTests {
    private func createPersistedSession(_ cwd: String, _ tempDir: String, _ label: String) throws -> String {
        let session = try SessionManager.create(cwd, tempDir)
        _ = try session.appendMessage(AgentMessage.user(UserMessage(content: .string(label), timestamp: dateNow())))
        _ = try session.appendMessage(AgentMessage.assistant(AssistantMessage(
            content: [.text(TextContent(text: "reply to \(label)"))],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "test",
            usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: UsageCost()),
            stopReason: .stop,
            timestamp: dateNow()
        )))
        guard let sessionFile = session.getSessionFile() else {
            throw PiError("Expected persisted session file")
        }
        return sessionFile
    }

    private func makeProjects() throws -> (tempDir: String, projectA: String, projectB: String) {
        let tempDir = try makeTempDir("session-test")
        let projectA = join(tempDir, "project-a")
        let projectB = join(tempDir, "project-b")
        try FileManager.default.createDirectory(atPath: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projectB, withIntermediateDirectories: true)
        return (tempDir, projectA, projectB)
    }

    @Test("scopes current-folder APIs by cwd while listing all flat sessions") func scopesByCwd() async throws {
        let (tempDir, projectA, projectB) = try makeProjects()
        defer { removeDir(tempDir) }
        let sessionA = try createPersistedSession(projectA, tempDir, "from A")
        try await pause()
        let sessionB = try createPersistedSession(projectB, tempDir, "from B")

        let currentA = try await SessionManager.list(projectA, tempDir)
        #expect(currentA.map(\.path) == [sessionA])

        let all = try await SessionManager.listAll(tempDir)
        #expect(Set(all.map(\.path)) == Set([sessionA, sessionB]))

        let continuedA = try SessionManager.continueRecent(projectA, tempDir)
        #expect(continuedA.getSessionFile() == sessionA)
    }

    @Test("rejects a cancelled session listing") func cancelledListing() async throws {
        let (tempDir, projectA, projectB) = try makeProjects()
        defer { removeDir(tempDir) }
        _ = try createPersistedSession(projectA, tempDir, "from A")
        _ = try createPersistedSession(projectB, tempDir, "from B")
        // Swift: session infos load on concurrent tasks, so with only two files both can finish before the
        // abort lands (in Node the second load always yields first). Files beyond the concurrency limit (10)
        // make the cancellation observable deterministically.
        for index in 0..<10 { _ = try createPersistedSession(projectA, tempDir, "extra \(index)") }
        let controller = AbortController()

        await #expect(throws: AbortError.self) {
            _ = try await SessionManager.listAll(tempDir, { _, _, partialSessions in
                if partialSessions != nil { controller.abort() }
            }, controller.signal)
        }
        await #expect(throws: AbortError.self) {
            _ = try await SessionManager.listAll(nil, nil, controller.signal)
        }
    }
}

@Suite("SessionManager.setSessionFile with corrupted files") struct CorruptedSessionFileTests {
    @Test("truncates and rewrites empty file with valid header") func rewritesEmptyFile() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let emptyFile = join(tempDir, "empty.jsonl")
        try write(emptyFile, "")

        let sm = try SessionManager.open(emptyFile, tempDir)

        // Should have created a new session with valid header
        #expect(!sm.getSessionId().isEmpty)
        let header = try #require(sm.getHeader())
        #expect(header.type == "session")

        // File should now contain a valid header
        let lines = try read(emptyFile).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        #expect(lines.count == 1)
        let parsed = try JsonValue.parse(String(lines[0]))
        #expect(parsed["type"]?.stringValue == "session")
        #expect(parsed["id"]?.stringValue == sm.getSessionId())
    }

    @Test("throws and preserves non-empty file without valid header") func preservesNoHeaderFile() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let noHeaderFile = join(tempDir, "no-header.jsonl")
        let originalContent =
            "{\"type\":\"message\",\"id\":\"abc\",\"parentId\":\"orphaned\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":\"test\"}}\n"
        try write(noHeaderFile, originalContent)

        #expect(thrownMessage { _ = try SessionManager.open(noHeaderFile, tempDir) }?.contains("Session file is not a valid pi session: \(noHeaderFile)") == true)
        #expect(try read(noHeaderFile) == originalContent)
    }

    @Test("throws and preserves non-session JSONL files") func preservesNonSessionFile() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let nonSessionFile = join(tempDir, "not-a-session.log")
        let originalContent = "{\"type\":\"event\",\"data\":\"not a session\"}\n"
        try write(nonSessionFile, originalContent)

        #expect(thrownMessage { _ = try SessionManager.open(nonSessionFile, tempDir) }?.contains("Session file is not a valid pi session: \(nonSessionFile)") == true)
        #expect(try read(nonSessionFile) == originalContent)
    }

    @Test("preserves explicit session file path when recovering from corrupted file") func preservesExplicitPath() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let explicitPath = join(tempDir, "my-session.jsonl")
        try write(explicitPath, "")

        let sm = try SessionManager.open(explicitPath, tempDir)

        // The session file path should be preserved
        #expect(sm.getSessionFile() == explicitPath)
    }

    @Test("subsequent loads of initialized empty file work correctly") func subsequentLoads() throws {
        let tempDir = try makeTempDir("session-test")
        defer { removeDir(tempDir) }
        let emptyFile = join(tempDir, "empty.jsonl")
        try write(emptyFile, "")

        let sm1 = try SessionManager.open(emptyFile, tempDir)
        let sessionId = sm1.getSessionId()

        let sm2 = try SessionManager.open(emptyFile, tempDir)
        #expect(sm2.getSessionId() == sessionId)
        #expect(sm2.getHeader()?.type == "session")
    }
}

@Suite("SessionManager session file creation") struct SessionFileCreationTests {
    @Test("does not create a file for a session with only setup entries") func noFileForSetupEntries() throws {
        let tempDir = try makeTempDir("pi-session-persist")
        defer { removeDir(tempDir) }
        let session = try SessionManager.create(tempDir, tempDir)
        _ = try session.appendModelChange("anthropic", "claude-sonnet-4-5")
        _ = try session.appendThinkingLevelChange("off")

        #expect(!FileManager.default.fileExists(atPath: try #require(session.getSessionFile())))
    }

    // #10000: the first prompt must survive a first turn that never produces an assistant message
    @Test("creates the file when the first user message is appended") func createsFileOnFirstUserMessage() throws {
        let tempDir = try makeTempDir("pi-session-persist")
        defer { removeDir(tempDir) }
        let session = try SessionManager.create(tempDir, tempDir)
        _ = try session.appendModelChange("anthropic", "claude-sonnet-4-5")
        _ = try session.appendMessage(userMsg("first question"))

        let file = try #require(session.getSessionFile())
        #expect(try readSessionFileRoles(file) == ["session", "model_change", "user"])
        #expect(try SessionManager.open(file, tempDir).buildSessionContext().messages.count == 1)
    }

    @Test("appends later entries to the file without rewriting earlier ones") func appendsLaterEntries() throws {
        let tempDir = try makeTempDir("pi-session-persist")
        defer { removeDir(tempDir) }
        let session = try SessionManager.create(tempDir, tempDir)
        _ = try session.appendMessage(userMsg("first question"))
        _ = try session.appendCustomEntry("preset-state", ["name": "plan"])
        _ = try session.appendMessage(assistantMsg("first answer"))

        #expect(try readSessionFileRoles(try #require(session.getSessionFile())) == ["session", "user", "custom", "assistant"])
    }
}
