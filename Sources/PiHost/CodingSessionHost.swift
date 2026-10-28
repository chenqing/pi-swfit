import Foundation
import PiAI
import PiAgent
import PiCodingAgent

public func codingSystemPrompt(cwd: String) -> String {
    "You are a coding assistant. Work in \(cwd). Read files before changing them. Use the available tools to complete the user's request. Never claim a tool succeeded without its result."
}

/// Both pf and PiChat use this construction path and the upstream JSONL session manager.
public final class CodingSessionHost: Sendable {
    public let session: AgentSession
    public let manager: SessionManager
    public let diagnostics: [ResourceDiagnostic]
    public let cwd: String
    public let paths: HostPaths
    public let connectionID: String?
    private let options: AgentOptions
    private let projectTrusted: Bool
    private let lease: HostFileLock?

    private init(created: CreateAgentSessionResult, manager: SessionManager, cwd: String, paths: HostPaths,
                 options: AgentOptions, projectTrusted: Bool, connectionID: String?, lease: HostFileLock?) {
        session = created.session; diagnostics = created.resourceDiagnostics; self.manager = manager
        self.cwd = cwd; self.paths = paths; self.options = options; self.projectTrusted = projectTrusted
        self.connectionID = connectionID; self.lease = lease
    }
    public static func open(cwd inputCwd: String, paths: HostPaths = .init(), manager: SessionManager? = nil,
                            options: AgentOptions, projectTrusted: Bool = false,
                            connectionID: String? = nil) async throws -> CodingSessionHost {
        let cwd = HostPaths.canonicalWorkspace(inputCwd)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PiError("The workspace folder is no longer available")
        }
        try paths.prepareSessionDirectory(cwd: cwd)
        let manager = try manager ?? SessionManager.create(cwd, paths.sessionDirectory(cwd: cwd))
        let lease = try manager.getSessionFile().map { try HostFileLock($0 + ".lock") }
        var options = options
        if options.streamFn == nil {
            options.streamFn = { model, context, options in
                try PiAI.streamSimple(model, Context(messages: context.messages), options)
            }
        }
        do {
            let created = try await createAgentSession(.init(cwd: cwd, agentDir: paths.agentDir,
                projectTrusted: projectTrusted, agentOptions: options, sessionManager: manager))
            if savedConnectionID(manager) != connectionID {
                do { _ = try manager.appendCustomEntry("pf.connection", connectionID.map(JsonValue.string)) }
                catch { await created.session.shutdown(); throw error }
            }
            return CodingSessionHost(created: created, manager: manager, cwd: cwd, paths: paths, options: options,
                                     projectTrusted: projectTrusted, connectionID: connectionID, lease: lease)
        } catch { lease?.release(); throw error }
    }
    public static func savedConnectionID(_ manager: SessionManager) -> String? {
        for entry in manager.getBranch().reversed() {
            if case .custom(let custom) = entry, custom.customType == "pf.connection" { return custom.data?.stringValue }
        }
        return nil
    }

    public func newConversation() async throws -> CodingSessionHost {
        let manager = try SessionManager.create(cwd, self.manager.getSessionDir())
        return try await Self.open(cwd: cwd, paths: paths, manager: manager, options: options,
                                   projectTrusted: projectTrusted, connectionID: connectionID)
    }
    public func shutdown() async { await session.shutdown(); lease?.release() }
}
