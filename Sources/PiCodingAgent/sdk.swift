// Native SDK construction path corresponding to core/sdk.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
// Not ported: model/auth discovery, built-in coding tools, TypeScript extension loading, package install,
// and model fallback selection. The host supplies its model, tools and auth callbacks explicitly.
import Foundation
import PiAI
import PiAgent

public struct CreateAgentSessionOptions: Sendable {
    public var extensions: [NativeExtension]
    public var mcp: McpExtensionOptions?
    public var codemode: CodemodeOptions?
    public var cwd: String
    public var agentDir: String
    public var projectTrusted: Bool
    public var agentOptions: AgentOptions
    public var settingsManager: SettingsManager?
    public var sessionManager: SessionManager?
    public var resourceLoader: (any ResourceLoader)?
    public init(cwd: String, agentDir: String = getAgentDir(), projectTrusted: Bool = false,
                agentOptions: AgentOptions, settingsManager: SettingsManager? = nil,
                sessionManager: SessionManager? = nil, resourceLoader: (any ResourceLoader)? = nil,
                extensions: [NativeExtension] = [], mcp: McpExtensionOptions? = nil, codemode: CodemodeOptions? = nil) {
        self.extensions = extensions; self.mcp = mcp; self.codemode = codemode
        self.cwd = cwd; self.agentDir = agentDir; self.projectTrusted = projectTrusted
        self.agentOptions = agentOptions; self.settingsManager = settingsManager
        self.sessionManager = sessionManager; self.resourceLoader = resourceLoader
    }
}
public struct CreateAgentSessionResult: Sendable {
    public let session: AgentSession
    public let resourceDiagnostics: [ResourceDiagnostic]
    public let mcp: McpExtensionRuntime?
}

public func createAgentSession(_ options: CreateAgentSessionOptions) async throws -> CreateAgentSessionResult {
    let settings = options.settingsManager ?? SettingsManager.create(cwd: options.cwd, agentDir: options.agentDir, projectTrusted: options.projectTrusted)
    let paths = settings.getExtensionPaths()
    func enabled(_ id: String, byDefault: Bool) -> Bool {
        var result = byDefault
        for path in paths {
            if path == id || path == "+" + id { result = true }
            if path == "-" + id || path == "!" + id { result = false }
        }
        return result
    }
    let mcp = enabled("builtin:mcp", byDefault: true) ? options.mcp.map {
        McpExtensionRuntime(options: $0, cwd: options.cwd, agentDir: options.agentDir, projectTrusted: options.projectTrusted)
    } : nil
    let autoCodemode = mcp != nil && loadMcpConfig(agentDir: options.agentDir, cwd: options.cwd, projectTrusted: options.projectTrusted).autoEnableCodemode != false
    let codemode = enabled("builtin:codemode", byDefault: options.codemode != nil || autoCodemode) ? (options.codemode ?? CodemodeOptions()) : nil
    let provided = Set(options.extensions.map(\.id))
    var extensions = options.extensions
    if let codemode, !provided.contains("builtin:codemode") { extensions.append(createCodemodeExtension(codemode)) }
    if enabled("builtin:tool-search", byDefault: mcp != nil), !provided.contains("builtin:tool-search") { extensions.append(createToolSearchExtension()) }
    if let mcp, !provided.contains("builtin:mcp") { extensions.append(mcp.makeExtension()) }
    let runner = try ExtensionRunner(extensions)
    let resources = options.resourceLoader ?? DefaultResourceLoader(.init(cwd: options.cwd, agentDir: options.agentDir,
        settingsManager: settings, projectTrusted: options.projectTrusted))
    try resources.reload()
    let skills = resources.getSkills()
    let initial = options.agentOptions.initialState ?? AgentInitialState()
    let toolNames = Set((initial.tools ?? []).map(\.name))
    let readTool = toolNames.contains("read") ? "read" : toolNames.contains("bash") ? "bash" : "indirect"
    let skillPrompt = formatSkillsForPrompt(skills.skills, fileReadTool: readTool)
    let manager = try options.sessionManager ?? SessionManager.inMemory(options.cwd)
    var agentOptions = options.agentOptions
    var restored = agentOptions.initialState ?? AgentInitialState()
    if restored.thinkingLevel == nil, manager.getBranch().contains(where: { $0.type == "thinking_level_change" }) {
        restored.thinkingLevel = ModelThinkingLevel(rawValue: manager.buildSessionContext().thinkingLevel)
    }
    if let model = restored.model, let level = restored.thinkingLevel {
        restored.thinkingLevel = clampThinkingLevel(model, level)
    }
    agentOptions.initialState = restored
    let agent = try Agent(agentOptions)
    if manager.getEntries().isEmpty {
        for message in await agent.state.messages { _ = try manager.appendMessage(message) }
    }
    if let level = restored.thinkingLevel, manager.buildSessionContext().thinkingLevel != level.rawValue {
        try manager.appendThinkingLevelChange(level.rawValue)
    }
    // A restored transcript may advertise tools from disabled or removed extensions. Reconcile
    // against this host's executable base tools before extensions publish their current catalogs.
    let previousTools = getCurrentTools(convertToLlm(manager.buildSessionContext().messages))
    let baseTools = (initial.tools ?? []).map(\.asTool)
    func declaration(_ tools: [Tool]) -> JsonValue {
        .array(tools.map { .object(["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters]) })
    }
    if declaration(previousTools) != declaration(baseTools) {
        _ = try manager.appendMessage(AgentMessage.system(SystemMessage(content: "", toolsAdded: baseTools,
            toolsRemoved: previousTools.map { ToolReference(name: $0.name) })))
    }
    // Named sections replace the previous skills catalog on resume without accumulating stale
    // descriptions or losing tool declarations. An empty catalog removes an old skills section.
    var previous: String?
    for message in manager.buildSessionContext().messages {
        if case .system(let system) = message {
            for section in system.sections ?? [] where section.name == "skills" { previous = section.text }
        }
    }
    let next: String? = skillPrompt.isEmpty ? nil : skillPrompt
    if previous != next {
        _ = try manager.appendMessage(AgentMessage.system(SystemMessage(content: "", sections: [("skills", next)])))
    }
    await agent.update { $0.state.messages = manager.buildSessionContext().messages }
    let session = await AgentSession(.init(agent: agent, sessionManager: manager, settingsManager: settings,
                                          cwd: options.cwd, resourceLoader: resources, extensionRunner: runner, projectTrusted: options.projectTrusted,
                                          initialActiveToolNames: Set(previousTools.map(\.name))))
    let unsupported = paths.filter {
        let name = $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix("!") ? String($0.dropFirst()) : $0
        return !["builtin:mcp", "builtin:tool-search", "builtin:codemode"].contains(name)
    }.map { ResourceDiagnostic(type: .warning, message: "Native Swift sessions cannot load this JavaScript/TypeScript extension path", path: $0) }
    return .init(session: session, resourceDiagnostics: skills.diagnostics + resources.getPrompts().diagnostics + unsupported, mcp: mcp)
}
