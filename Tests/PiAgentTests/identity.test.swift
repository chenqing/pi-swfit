import Testing
import PiAI
@testable import PiAgent

@Suite("Agent request identity")
struct AgentIdentityTests {
    @Test func forwardsDefaultOverridesAndExplicitDisable() async throws {
        let received = Locked<[ClientIdentity?]>([])
        let agent = try Agent(.init(streamFn: { _, _, options in
            received.withLock { $0.append(options?.identity) }
            return respond { done(createAssistantMessage("ok")) }
        }))
        try await agent.prompt("first")
        let app = ClientAttribution(name: "app", url: "https://example.test")
        await agent.update { $0.identity = .init(userAgent: .short, attribution: .some(app)) }
        try await agent.prompt("second")
        await agent.update { $0.identity = .init(attribution: .some(nil)) }
        try await agent.prompt("third")
        #expect(received.current == [DEFAULT_AGENT_IDENTITY, .init(userAgent: .short, attribution: .some(app)), .init(attribution: .some(nil))])
    }
}
