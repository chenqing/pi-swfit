// Tool exposure/loadout contracts from core/extensions/types.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
import Foundation
import PiAI
import PiAgent

public enum ToolExposure: String, Sendable { case direct, deferred, codemode, hidden; case modelOnly = "model-only" }
public struct ExtensionTool: Sendable {
    public var tool: AgentTool
    public var exposure: ToolExposure
    public var namespace: String?
    public var version: UUID?
    public init(_ tool: AgentTool, exposure: ToolExposure = .direct, namespace: String? = nil, version: UUID? = nil) {
        self.tool = tool; self.exposure = exposure; self.namespace = namespace; self.version = version
    }
}
public struct ExtensionToolInfo: Sendable {
    public let tool: AgentTool
    public let exposure: ToolExposure
    public let namespace: String?
    public let active: Bool
}

final class ExtensionToolCatalog: Sendable {
    struct Owned: Sendable {
        let owner: String
        let lease: AbortController
        let registration: ExtensionTool
    }
    struct State: Sendable {
        var entries: [String: Owned] = [:]
        var order: [String] = []
        var activated: Set<String> = []
    }
    let state = Locked(State())
    func invalidate() {
        let old = state.withLock { let old = Array($0.entries.values); $0.entries.removeAll(); $0.order = []; return old }
        old.forEach { $0.lease.abort() }
    }
    func infos() -> [ExtensionToolInfo] {
        state.withLock { state in state.order.compactMap { name in
            guard let owned = state.entries[name] else { return nil }
            let value = owned.registration
            return .init(tool: value.tool, exposure: value.exposure, namespace: value.namespace,
                         active: value.exposure == .direct || value.exposure == .modelOnly || (value.exposure != .hidden && state.activated.contains(name)))
        } }
    }
}
