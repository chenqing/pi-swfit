import Foundation
import Testing
import PiAI
import PiAgent
@testable import PiCLI

@Suite("pf CLI")
struct CLITests {
    @Test func flagsAndUnsupportedModes() throws {
        let args = try CLIArguments(["--mode", "json", "-p", "--no-session", "--tools", "read,edit", "--model", "fixture", "hello"])
        #expect(args.mode == "json" && args.printMode && args.noSession)
        #expect(args.tools == ["read", "edit"])
        #expect(args.messages == ["hello"])
        #expect(throws: (any Error).self) { try CLIArguments(["--mode", "rpc"]) }
        #expect(throws: (any Error).self) { try CLIArguments(["--model"]) }
        #expect(throws: (any Error).self) { try CLIArguments(["--continue", "--no-session"]) }
        #expect(try CLIArguments(["--connection", "Work", "-c"]).connection == "Work")
        #expect(try CLIArguments(["--list-connections"]).listConnections)
        #expect(throws: (any Error).self) { try CLIArguments(["--connection", "Work", "--base-url", "https://example.invalid"]) }
    }

    @Test func editUsesOriginalFileAndRejectsOverlap() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sample.txt")
        try "alpha beta gamma".write(to: file, atomically: true, encoding: .utf8)
        let edit = try #require(createCodingTools(cwd: dir.path).first { $0.name == "edit" })
        _ = try await edit.execute("1", ["path": "sample.txt", "edits": [["oldText": "alpha", "newText": "gamma"], ["oldText": "gamma", "newText": "omega"]]], nil, nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "gamma beta omega")
        await #expect(throws: (any Error).self) {
            try await edit.execute("2", ["path": "sample.txt", "edits": [["oldText": "gamma beta", "newText": "x"], ["oldText": "beta", "newText": "y"]]], nil, nil)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "gamma beta omega")
    }

    @Test func writeAndReadPages() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = createCodingTools(cwd: dir.path)
        let write = try #require(tools.first { $0.name == "write" })
        let read = try #require(tools.first { $0.name == "read" })
        _ = try await write.execute("1", ["path": "nested/test.txt", "content": "one\ntwo\nthree"], nil, nil)
        let result = try await read.execute("2", ["path": "nested/test.txt", "offset": 2, "limit": 1], nil, nil)
        guard case .text(let text)? = result.content.first else { Issue.record("Missing read output"); return }
        #expect(text.text.hasPrefix("two\n"))
        #expect(text.text.contains("offset=3"))
    }

    @Test func shellReportsFailureAndCancelsProcessGroup() async throws {
        let dir = FileManager.default.temporaryDirectory
        let bash = try #require(createCodingTools(cwd: dir.path).first { $0.name == "bash" })
        let result = try await bash.execute("1", ["command": "printf fixture; exit 7"], nil, nil)
        #expect(result.isError == true)
        #expect(result.structuredContent?["exit_code"]?.doubleValue == 7)
        let start = Date()
        await #expect(throws: (any Error).self) {
            try await bash.execute("2", ["command": "sleep 30", "timeout": 0.1], nil, nil)
        }
        #expect(Date().timeIntervalSince(start) < 3)
        let controller = AbortController()
        let task = Task { try await bash.execute("3", ["command": "sleep 30"], controller.signal, nil) }
        try await Task.sleep(for: .milliseconds(50)); controller.abort()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func jsonKeepsUpstreamEventShape() throws {
        let message = AssistantMessage(content: [.text(TextContent(text: "Hi"))], api: "openai-completions", provider: "test", model: "fixture")
        let event = try #require(jsonEvent(.messageUpdate(message: .assistant(message), assistantMessageEvent: .textDelta(contentIndex: 0, delta: "Hi", partial: message))))
        #expect(event["type"]?.stringValue == "message_update")
        #expect(event["assistantMessageEvent"]?["type"]?.stringValue == "text_delta")
        #expect(event["assistantMessageEvent"]?["delta"]?.stringValue == "Hi")
        #expect(event["message"]?["role"]?.stringValue == "assistant")
    }
}
