import Foundation
import PiAI
import PiAgent
@testable import PiCodingAgent

// Port of test/suite/harness.ts (subset)
//
// Swift: the faux core is wired in as the agent's `streamFn` instead of a registered provider, and the agent's
// `getApiKey` supplies "faux-key".
// Not ported: AuthStorage / ModelRegistry / modelsJson, resource loader, extension factories and runner hooks
// (onPayload / onResponse / transformContext), tool allow/exclude lists, createTestUiContext.

/** Text of a message's `content` (string, or its text parts joined by newlines). */
func getMessageText(_ message: AgentMessage) -> String {
    func join(_ blocks: [UserContent]) -> String {
        blocks.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }.joined(separator: "\n")
    }
    switch message {
    case .user(let user):
        switch user.content {
        case .string(let text): return text
        case .blocks(let blocks): return join(blocks)
        }
    case .assistant(let assistant):
        return assistant.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }.joined(separator: "\n")
    case .toolResult(let result):
        return join(result.content)
    case .custom:
        if let custom = CustomMessage(message) {
            switch custom.content {
            case .string(let text): return text
            case .blocks(let blocks): return join(blocks)
            }
        }
        return ""
    case .system:
        return ""
    }
}

func getUserTexts(_ harness: Harness) async -> [String] {
    await harness.session.messages.filter { $0.role == "user" }.map(getMessageText)
}

func getAssistantTexts(_ harness: Harness) async -> [String] {
    await harness.session.messages.filter { $0.role == "assistant" }.map(getMessageText)
}

struct HarnessOptions {
    var models: [FauxModelDefinition]?
    var settings: Settings?
    var tools: [AgentTool]?
    /** Session to continue, for example to test a resume. Default: a new in-memory session. */
    var sessionManager: SessionManager?
    init(models: [FauxModelDefinition]? = nil, settings: Settings? = nil, tools: [AgentTool]? = nil, sessionManager: SessionManager? = nil) {
        self.models = models; self.settings = settings; self.tools = tools; self.sessionManager = sessionManager
    }
}

final class Harness: Sendable {
    let session: AgentSession
    let sessionManager: SessionManager
    let settingsManager: SettingsManager
    let faux: FauxCore
    let tempDir: String
    private let _events = Collector<AgentSessionEvent>()

    fileprivate init(session: AgentSession, sessionManager: SessionManager, settingsManager: SettingsManager, faux: FauxCore, tempDir: String) {
        self.session = session; self.sessionManager = sessionManager; self.settingsManager = settingsManager
        self.faux = faux; self.tempDir = tempDir
        let events = _events
        _ = session.subscribe { events.append($0) }
    }

    var models: [Model] { faux.models }
    func getModel() -> Model { faux.getModel() }
    func getModel(_ modelId: String) -> Model? { faux.getModel(modelId) }
    func setResponses(_ responses: [FauxResponseStep]) { faux.setResponses(responses) }
    func appendResponses(_ responses: [FauxResponseStep]) { faux.appendResponses(responses) }
    func getPendingResponseCount() -> Int { faux.getPendingResponseCount() }
    var events: [AgentSessionEvent] { _events.values }
    func eventsOfType(_ type: String) -> [AgentSessionEvent] { events.filter { $0.type == type } }

    func cleanup() {
        session.dispose()
        try? FileManager.default.removeItem(atPath: tempDir)
    }
}

/// Stand-in for the system prompt AgentSession builds upstream.
let HARNESS_SYSTEM_PROMPT = "You are a test assistant."

func createHarness(_ options: HarnessOptions = HarnessOptions()) async throws -> Harness {
    let tempDir = try makeTempDir("pi-suite")
    let faux = createFauxCore(RegisterFauxProviderOptions(models: options.models))
    faux.setResponses([])
    let model = faux.getModel()

    let sessionManager = try options.sessionManager ?? SessionManager.inMemory()
    let settingsManager = SettingsManager.inMemory(options.settings ?? Settings())

    let agent = try Agent(AgentOptions(
        // Swift: upstream passes "" and AgentSession rebuilds a non-empty prompt from the resource loader;
        // the system prompt builder is not ported, so a fixed prompt stands in for it.
        initialState: AgentInitialState(systemPrompt: HARNESS_SYSTEM_PROMPT, model: model, tools: options.tools ?? []),
        convertToLlm: { convertToLlm($0) },
        streamFn: { model, context, options in faux.streamSimple(model, context, options) },
        getApiKey: { _ in "faux-key" }
    ))

    let session = await AgentSession(AgentSessionConfig(
        agent: agent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        cwd: tempDir
    ))

    return Harness(session: session, sessionManager: sessionManager, settingsManager: settingsManager, faux: faux, tempDir: tempDir)
}
