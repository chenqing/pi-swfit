import Foundation
import Testing
import PiAI
@testable import PiChat

struct ChatPermissionModeTests {
    @Test func modeMatrixRecognizesOnlyHostOwnedWorkspaceTools() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("permission-matrix").path
        let args: JsonValue = ["path": "Sources/example.swift"]
        #expect(!ChatPermissionMode.manual.requiresApproval(tool: "read", arguments: args, workspace: root))
        #expect(ChatPermissionMode.manual.requiresApproval(tool: "edit", arguments: args, workspace: root))
        for tool in ["read", "edit", "write"] {
            #expect(!ChatPermissionMode.acceptEdits.requiresApproval(tool: tool, arguments: args, workspace: root))
            #expect(ChatPermissionMode.acceptEdits.requiresApproval(tool: tool, arguments: args, workspace: nil))
        }
        for tool in ["bash", "mcp__read", "read_other", "custom"] {
            #expect(ChatPermissionMode.acceptEdits.requiresApproval(tool: tool, arguments: args, workspace: root))
            #expect(!ChatPermissionMode.bypassPermissions.requiresApproval(tool: tool, arguments: args, workspace: root))
        }
        #expect(ChatPermissionMode.manual.requiresApproval(tool: "read", arguments: [:], workspace: root))
    }

    @Test func pathsOutsideWorkspaceAndAgentConfigurationRequireApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("permission-paths-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("missing-" + UUID().uuidString))
        for path in ["../other.txt", root.path + "-sibling/file", "outside/not-created-yet/file", "dangling/file"] {
            #expect(ChatPermissionMode.manual.requiresApproval(tool: "read", arguments: ["path": .string(path)], workspace: root.path))
            #expect(ChatPermissionMode.acceptEdits.requiresApproval(tool: "write", arguments: ["path": .string(path)], workspace: root.path))
        }
        for path in [".git/config", ".pi/settings.json", "nested/.pf/agent.json"] {
            #expect(ChatPermissionMode.acceptEdits.requiresApproval(tool: "write", arguments: ["path": .string(path)], workspace: root.path))
        }
        #expect(!ChatPermissionMode.acceptEdits.requiresApproval(tool: "write", arguments: ["path": "new/folder/file.swift"], workspace: root.path))
    }
}
