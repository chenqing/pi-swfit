import Foundation
import Testing
import PiAI
import PiAgent
#if canImport(Darwin)
import Darwin
#endif
@testable import PiCodingAgent

private struct ResourceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-resources-\(UUID())")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func path(_ value: String) -> String { root.appendingPathComponent(value).path }
}

@Suite("Pi resource configuration") struct PiResourceTests {
    @Test func frontmatter() throws {
        let result = try parseFrontmatter("\u{feff}---\r\nname: \"skill-name\"\r\ndescription: |\r\n  Line one\r\n  Line two\r\n---\r\n\r\nBody text")
        #expect(result.frontmatter["name"] == .string("skill-name"))
        #expect(result.frontmatter["description"] == .string("Line one\nLine two\n"))
        #expect(result.body == "Body text")
        #expect(try stripFrontmatter("\n  No frontmatter body  \n") == "\n  No frontmatter body  \n")
        #expect(try parseFrontmatter("---\n# comment\n---\nBody").frontmatter == .emptyObject)
        #expect(throws: (any Error).self) { try parseFrontmatter("---\nfoo: [bar\n---\nBody") }
        #expect(throws: (any Error).self) { try parseFrontmatter("---\nname: a\nname: b\n---\nBody") }
    }
    @Test func yaml12Types() throws {
        let result = try parseFrontmatter("---\nname: yes\ndescription: 2026-10-23\ndisable-model-invocation: true\nquoted: 'false'\n---\nBody")
        #expect(result.frontmatter["name"] == .string("yes"))
        #expect(result.frontmatter["description"] == .string("2026-10-23"))
        #expect(result.frontmatter["disable-model-invocation"] == .bool(true))
        #expect(result.frontmatter["quoted"] == .string("false"))
    }
    @Test func discoveryAndWarnings() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        try fixture.write("root/SKILL.md", "---\nname: Bad--Name\ndescription: still loads\n---\nBody")
        try fixture.write("root/nested/SKILL.md", "---\nname: child\ndescription: nested\n---\nBody")
        let result = loadSkillsFromDir(.init(dir: fixture.path("root"), source: "user"))
        #expect(result.skills.map(\.name) == ["Bad--Name"])
        #expect(result.diagnostics.count == 2)
        #expect(result.skills.first?.sourceInfo.scope == .user)
        try fixture.write("empty/SKILL.md", "---\nname: empty\n---\nBody")
        #expect(loadSkillsFromDir(.init(dir: fixture.path("empty"), source: "path")).skills.isEmpty)
    }
    @Test func ignoresLinksAndCollisions() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        for name in ["one", "two", "skip", "keep"] {
            try fixture.write("skills/\(name)/SKILL.md", "---\nname: \(name == "two" ? "one" : name)\ndescription: Works\n---\nBody")
        }
        try fixture.write("skills/.gitignore", "skip/\nkeep/\n!keep/\n")
        try FileManager.default.createSymbolicLink(atPath: fixture.path("skills/one/cycle"), withDestinationPath: fixture.path("skills"))
        try FileManager.default.createSymbolicLink(atPath: fixture.path("alias"), withDestinationPath: fixture.path("skills/one"))
        let result = loadSkills(.init(cwd: fixture.root.path, agentDir: fixture.path("agent"), skillPaths: ["skills", "alias"], includeDefaults: false))
        #expect(result.skills.map(\.name) == ["keep", "one"])
        #expect(result.diagnostics.filter { $0.type == .collision }.count == 1)
        #expect(result.diagnostics.last?.collision?.winnerPath.hasSuffix("one/SKILL.md") == true)
    }
    @Test func explicitHiddenSkill() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        try fixture.write("private/SKILL.md", "---\nname: private\ndescription: Explicit only\ndisable-model-invocation: true\n---\nDo the work.")
        let result = loadSkillsFromDir(.init(dir: fixture.path("private"), source: "user"))
        #expect(formatSkillsForPrompt(result.skills).isEmpty)
        let expanded = try expandSkillCommand("/skill:private extra instructions", skills: result.skills)
        #expect(expanded.contains("References are relative to"))
        #expect(expanded.hasSuffix("</skill>\n\nextra instructions"))
        #expect(try expandSkillCommand("/skill:missing", skills: result.skills) == "/skill:missing")
    }
    @Test func scopedSettingsAndPreservation() throws {
        let storage = InMemorySettingsStorage(global: #"{"skills":["global"],"unknown":{"keep":1},"retry":{"enabled":true,"maxRetries":9}}"#,
                                              project: #"{"skills":["local"],"retry":{"enabled":false}}"#)
        let trusted = SettingsManager.fromStorage(storage)
        #expect(trusted.getSkillPaths() == ["local"])
        #expect(trusted.getRetryEnabled() == false)
        trusted.setSkillPaths(["changed"])
        #expect(trusted.getSkillPaths() == ["local"])
        let untrusted = SettingsManager.fromStorage(storage, projectTrusted: false)
        #expect(untrusted.getSkillPaths() == ["changed"])
        #expect(untrusted.getGlobalSettings()["unknown"]?["keep"] == .number(1))
        #expect(untrusted.getRetrySettings().maxRetries == 9)
        #expect(throws: PiError.self) { try untrusted.setProjectSkillPaths(["forbidden"]) }
    }
    @Test func malformedSettingsAreNotOverwritten() throws {
        let storage = InMemorySettingsStorage(global: "{invalid")
        let manager = SettingsManager.fromStorage(storage)
        #expect(manager.drainErrors().count == 1)
        manager.setEnableSkillCommands(false)
        #expect(manager.drainErrors().count == 1)
        try storage.withLock(.global) { current in #expect(current == "{invalid"); return nil }
    }
    @Test func configPathsAndTrust() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        try fixture.write("agent/custom/SKILL.md", "---\nname: global\ndescription: Global\n---\nBody")
        try fixture.write("project/.pi/skills/local/SKILL.md", "---\nname: local\ndescription: Local\n---\nBody")
        try fixture.write("agent/settings.json", #"{"skills":["custom"]}"#)
        let settings = SettingsManager.create(cwd: fixture.path("project"), agentDir: fixture.path("agent"), projectTrusted: false)
        let loader = DefaultResourceLoader(.init(cwd: fixture.path("project"), agentDir: fixture.path("agent"), settingsManager: settings, homeDir: fixture.path("home")))
        try loader.reload()
        #expect(loader.getSkills().skills.map(\.name) == ["global"])
    }
    @Test func concurrentSettingsEditsKeepOtherFields() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        let first = SettingsManager.create(cwd: fixture.path("project"), agentDir: fixture.path("agent"))
        let second = SettingsManager.create(cwd: fixture.path("project"), agentDir: fixture.path("agent"))
        first.setSkillPaths(["one"])
        second.setEnableSkillCommands(false)
        first.reload()
        #expect(first.getSkillPaths() == ["one"])
        #expect(!first.getEnableSkillCommands())
        #expect(first.drainErrors().isEmpty && second.drainErrors().isEmpty)
    }
    @Test func mcpConfigMergeAndExposure() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        try fixture.write("agent/mcp.json", #"{"mcpServers":{"service":{"url":"https://example.com/mcp","auth":{"provider":"secret"},"toolExposure":{"*":"hidden","read*":"direct","read_file":"deferred"}},"local":{"command":"echo"}}}"#)
        try fixture.write("project/.pi/mcp.json", #"{"mcpServers":{"service":{"enabled":false},"bad":{"url":"https://evil.example/mcp","auth":{"provider":"secret"}}}}"#)
        let loaded = loadMcpConfig(agentDir: fixture.path("agent"), cwd: fixture.path("project"), projectTrusted: true)
        #expect(loaded.servers.count == 2 && loaded.errors.count == 1)
        let service = try #require(loaded.servers.first)
        #expect(!service.config.enabled)
        #expect(service.config.value["auth"]?["provider"] == .string("secret"))
        #expect(getMcpToolExposure(config: service.config, toolName: "read_file") == .deferred)
        #expect(getMcpToolExposure(config: service.config, toolName: "read_other") == .hidden)
        #expect(loaded.servers[1].config.exposure == .codemode)
        let untrusted = loadMcpConfig(agentDir: fixture.path("agent"), cwd: fixture.path("project"), projectTrusted: false)
        #expect(untrusted.servers.first?.config.enabled == true)
    }
    @Test func mcpValidationAndRegistryOwnership() throws {
        #expect(throws: PiError.self) { try validateMcpServerConfig(name: "bad/name", raw: .object(["command": .string("echo")])) }
        #expect(throws: PiError.self) { try validateMcpServerConfig(name: "server", raw: .object(["url": .string("http://example.com"), "auth": .object(["provider": .string("token")])])) }
        let config = try validateMcpServerConfig(name: "server", raw: .object(["command": .string("echo"), "exposure": .string("codemode-deferred")]))
        #expect(config.exposure == .codemode)
        let registry = McpServerRegistry()
        registry.register(.init(name: "server", config: config, extensionPath: "owner"))
        registry.unregister(name: "server", extensionPath: "other")
        #expect(registry.list().count == 1)
        registry.unregister(name: "server", extensionPath: "owner")
        #expect(registry.list().isEmpty)
    }
    @Test func sdkUsesSkillsInRealSessionPipeline() async throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        try fixture.write("agent/skills/sample/SKILL.md", "---\nname: sample\ndescription: Example skill\n---\nFollow the reference.")
        let settings = SettingsManager.inMemory(.init(compaction: .init(enabled: false), retry: .init(enabled: false)))
        settings.setEnableSkillCommands(false) // Discovery preference does not disable explicit invocation.
        let resources = DefaultResourceLoader(.init(cwd: fixture.path("project"), agentDir: fixture.path("agent"), settingsManager: settings, homeDir: fixture.path("home")))
        let model = Model(id: "fixture", name: "Fixture", api: "openai-completions", provider: "test", baseUrl: "https://fixture.invalid", reasoning: false, input: ["text"], contextWindow: 100_000, maxTokens: 1000)
        let agentOptions = AgentOptions(initialState: .init(systemPrompt: "Base instruction", model: model), streamFn: { model, _, _ in
            let stream = AssistantMessageEventStream()
            let message = AssistantMessage(content: [.text(.init(text: "done"))], api: model.api, provider: model.provider, model: model.id, usage: Usage(), stopReason: .stop, timestamp: dateNow())
            stream.push(.done(reason: .stop, message: message))
            return stream
        })
        let created = try await createAgentSession(.init(cwd: fixture.path("project"), agentDir: fixture.path("agent"), agentOptions: agentOptions, settingsManager: settings, resourceLoader: resources))
        defer { created.session.dispose() }
        try await created.session.prompt("/skill:sample answer now")
        let messages = created.session.sessionManager.buildSessionContext().messages
        let user = try #require(messages.last(where: { $0.role == "user" }).flatMap(firstText))
        #expect(parseSkillBlock(user)?.name == "sample")
        #expect(parseSkillBlock(user)?.userMessage == "answer now")
        #expect(messages.contains { message in
            if case .system(let system) = message { return system.sections?.contains { $0.name == "skills" && ($0.text?.contains("Example skill") ?? false) } ?? false }
            return false
        })
        let before = created.session.sessionManager.getEntries().count
        let resumed = try await createAgentSession(.init(cwd: fixture.path("project"), agentDir: fixture.path("agent"), agentOptions: agentOptions, settingsManager: settings, sessionManager: created.session.sessionManager, resourceLoader: resources))
        defer { resumed.session.dispose() }
        #expect(resumed.session.sessionManager.getEntries().count == before)
        try await resumed.session.prompt("/skill:sample", .init(expandPromptTemplates: false))
        #expect(resumed.session.sessionManager.buildSessionContext().messages.last(where: { $0.role == "user" }).flatMap(firstText) == "/skill:sample")
    }
    @Test func resourceFiltersApplyBeforeNameCollisions() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        try fixture.write("agent/first/SKILL.md", "---\nname: same\ndescription: First\n---\nBody")
        try fixture.write("agent/second/SKILL.md", "---\nname: same\ndescription: Second\n---\nBody")
        let settings = SettingsManager.inMemory()
        settings.setSkillPaths(["first", "second", "-first", "+first"])
        let loader = DefaultResourceLoader(.init(cwd: fixture.path("project"), agentDir: fixture.path("agent"), settingsManager: settings, homeDir: fixture.path("home")))
        try loader.reload()
        // Exact exclusion wins even when a force-include is written later.
        #expect(loader.getSkills().skills.map(\.description) == ["Second"])
        #expect(loader.getSkills().diagnostics.isEmpty)
    }
    @Test func legacySettingsMigrateWithoutChangingFileOnRead() throws {
        let original = #"{"queueMode":"all","websockets":true,"skills":{"customDirectories":["custom"],"enableSkillCommands":false},"retry":{"maxDelayMs":1234},"custom":"keep"}"#
        let storage = InMemorySettingsStorage(global: original)
        let settings = SettingsManager.fromStorage(storage)
        #expect(settings.getSkillPaths() == ["custom"])
        #expect(!settings.getEnableSkillCommands())
        #expect(settings.getProviderRetrySettings().maxRetryDelayMs == 1234)
        try storage.withLock(.global) { text in #expect(text == original); return nil }
        settings.setSkillPaths(["next"])
        #expect(settings.drainErrors().isEmpty)
        try storage.withLock(.global) { text in
            let object = try JsonValue.parse(text!)
            #expect(object["custom"] == .string("keep"))
            #expect(object["transport"] == .string("websocket"))
            #expect(object["retry"]?["maxDelayMs"] == nil)
            return nil
        }
    }
    @Test func mcpEditsPreserveIndentAndExplicitProjectDefaults() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        try fixture.write("mcp.json", "{\n\t\"other\": true,\n\t\"mcpServers\": {\"local\": {\"command\": \"echo\", \"enabled\": false}}\n}\n")
        try updateMcpServerConfig(path: fixture.path("mcp.json"), name: "local", patch: .init(enabled: true, exposure: .codemode))
        let text = try String(contentsOfFile: fixture.path("mcp.json"), encoding: .utf8)
        #expect(text.contains("\n\t\"other\": true"))
        #expect(try JsonValue.parse(text)["mcpServers"]?["local"]?["enabled"] == nil)
        try updateMcpServerConfig(path: fixture.path("project.json"), name: "local", patch: .init(enabled: true, exposure: .codemode), override: true)
        let project = try JsonValue.parse(String(contentsOfFile: fixture.path("project.json"), encoding: .utf8))
        #expect(project["mcpServers"]?["local"]?["enabled"] == .bool(true))
        #expect(project["mcpServers"]?["local"]?["exposure"] == .string("codemode"))
    }
    @Test func settingsHonorActiveAndRecoverStaleDirectoryLocks() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        try fixture.write("agent/settings.json", "{}")
        let storage = FileSettingsStorage(cwd: fixture.path("project"), agentDir: fixture.path("agent"))
        let lock = fixture.path("agent/settings.json.lock")
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        #expect(throws: PiError.self) { try storage.withLock(.global) { _ in "{\"skills\":[]}" } }
        #expect(try String(contentsOfFile: storage.globalSettingsPath, encoding: .utf8) == "{}")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30)], ofItemAtPath: lock)
        try storage.withLock(.global) { _ in "{\"skills\":[]}" }
        #expect(!FileManager.default.fileExists(atPath: lock))
    }
    @Test func yamlAliasesAreBounded() throws {
        #expect(try parseFrontmatter("---\nname: &name sample\ndescription: *name\n---\nBody").frontmatter["description"] == .string("sample"))
        var yaml = "---\na: &a [x,x,x,x,x,x,x,x,x,x]\n"
        for (previous, next) in zip(["a", "b", "c", "d", "e"], ["b", "c", "d", "e", "f"]) {
            yaml += "\(next): &\(next) [" + Array(repeating: "*" + previous, count: 10).joined(separator: ",") + "]\n"
        }
        yaml += "---\nBody"
        #expect(throws: PiError.self) { try parseFrontmatter(yaml) }
    }
    #if canImport(Darwin)
    @Test func skillDiscoverySkipsNamedPipes() throws {
        let fixture = try ResourceFixture(); defer { fixture.cleanup() }
        #expect(mkfifo(fixture.path("SKILL.md"), S_IRUSR | S_IWUSR) == 0)
        let result = loadSkillsFromDir(.init(dir: fixture.root.path, source: "test"))
        #expect(result.skills.isEmpty)
    }
    #endif
}
