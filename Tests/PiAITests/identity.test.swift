import Foundation
import Testing
@testable import PiAI

@Suite("Client identity")
struct ClientIdentityTests {
    private let acme = ClientAttribution(name: "acme", url: "https://acme.example", categories: ["reader"])
    private func headers(_ value: ProviderHeaders) -> [String: String] {
        Dictionary(uniqueKeysWithValues: value.compactMap { key, value in value.map { (key, $0) } })
    }
    @Test func mergesAndPreservesExplicitNullThroughCodable() throws {
        #expect(mergeClientIdentity(nil, nil) == nil)
        let base = ClientIdentity(userAgent: .short, attribution: .some(PI_ATTRIBUTION))
        let inherited = mergeClientIdentity(base, .init(version: "9.9.9"))
        #expect(inherited?.userAgent == .short)
        #expect(inherited?.attribution == .some(.some(PI_ATTRIBUTION)))
        let disabled = try JSONDecoder().decode(ClientIdentity.self, from: Data(#"{"attribution":null}"#.utf8))
        #expect(mergeClientIdentity(base, disabled)?.attribution == .some(nil))
        #expect(try JsonValue.parse(String(decoding: JSONEncoder().encode(disabled), as: UTF8.self)) == ["attribution": nil])
        #expect(formatUserAgent(.init(userAgent: .short)) == "pi")
        #expect(formatUserAgent(.init(userAgent: .custom("Pagie/1"))) == "Pagie/1")
        #expect(formatUserAgent(.init(version: "9.9.9")).hasPrefix("pi/9.9.9 ("))
    }
    @Test func targetAttributionAndCustomOpenCodeRouting() {
        let identity = ClientIdentity(attribution: .some(acme))
        let router = ClientIdentityTarget(provider: "custom", baseUrl: "https://openrouter.ai/api/v1")
        #expect(getAttributionHeaders(router).isEmpty)
        #expect(headers(getAttributionHeaders(router, identity)) == ["HTTP-Referer": acme.url, "X-OpenRouter-Title": "acme", "X-OpenRouter-Categories": "reader"])
        #expect(headers(getAttributionHeaders(.init(provider: "custom", baseUrl: "https://integrate.api.nvidia.com/v1"), identity)) == ["X-BILLING-INVOKE-ORIGIN": "Acme"])
        let code = ClientIdentityTarget(provider: "custom", baseUrl: "https://opencode.ai/zen/v1")
        #expect(headers(getAttributionHeaders(code, identity)) == ["x-opencode-client": "acme"])
        #expect(headers(getOpenCodeSessionHeaders(code, "session") ?? []) == ["x-opencode-session": "session"])
        #expect(getOpenCodeSessionHeaders(.init(provider: "custom", baseUrl: "https://opencode.ai.example/v1"), "session") == nil)
    }
    @Test func directAndSimpleRequestsRespectIdentityAndHeaderOverrides() async throws {
        let server = CFakeServer()
        let model = Model(id: "test", name: "test", api: "openai-completions", provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", maxTokens: 1000)
        var options = SimpleStreamOptions()
        options.apiKey = "synthetic"; options.fetch = server.fetch
        options.identity = .init(userAgent: .custom("acme/1"), attribution: .some(acme))
        let context = normalizeContext(cUserContext("hello"))
        #expect(await streamSimpleOpenAICompletions(model, context, options).result().stopReason == .stop)
        let first = try #require(server.requests.first)
        #expect(first.headers.get("User-Agent") == "acme/1")
        #expect(first.headers.get("X-OpenRouter-Title") == "acme")
        options.headers = [("User-Agent", "override"), ("HTTP-Referer", nil), ("X-OpenRouter-Title", "explicit")]
        #expect(await streamOpenAICompletions(model, context, options).result().stopReason == .stop)
        let last = try #require(server.requests.last)
        #expect(last.headers.get("User-Agent") == "override")
        #expect(last.headers.get("HTTP-Referer") == nil)
        #expect(last.headers.get("X-OpenRouter-Title") == "explicit")
    }
    @Test func modelsDefaultAndRequestIdentityMerge() async throws {
        let server = CFakeServer()
        let model = Model(id: "test", name: "test", api: "openai-completions", provider: "custom", baseUrl: "https://opencode.ai/zen/v1", maxTokens: 1000)
        let models = createModels(.init(identity: .init(userAgent: .short, attribution: .some(acme))))
        let auth = ProviderAuth(apiKey: ApiKeyAuth(name: "fixture", resolve: { _ in AuthResult(auth: ModelAuth(apiKey: "synthetic")) }))
        models.setProvider(try createProvider(.init(id: "custom", auth: auth, models: [model], api: .single(.init(
            stream: { model, context, options in streamOpenAICompletions(model, context, options) },
            streamSimple: { model, context, options in streamSimpleOpenAICompletions(model, context, options) })))))
        var options = SimpleStreamOptions(); options.fetch = server.fetch; options.sessionId = "conversation"
        options.identity = .init(attribution: .some(nil))
        let result = await models.completeSimple(model, cUserContext("hello"), options)
        #expect(result.stopReason == .stop)
        let request = try #require(server.requests.first)
        #expect(request.headers.get("User-Agent") == "pi")
        #expect(request.headers.get("x-opencode-client") == nil)
        #expect(request.headers.get("x-opencode-session") == "conversation")

        let wrapped = withClientIdentity(models, .init(userAgent: .custom("wrapped/1")))
        #expect(wrapped.getProvider("custom")?.id == "custom")
        #expect((withClientIdentity(models as any Models, .init()) as? any MutableModels) != nil)
        #expect(await wrapped.completeSimple(model, cUserContext("hello"), options).stopReason == .stop)
        #expect(server.requests.last?.headers.get("User-Agent") == "wrapped/1")
        #expect(server.requests.last?.headers.get("x-opencode-client") == nil)
        options.identity = .init(userAgent: .custom("request/1"))
        #expect(await wrapped.completeSimple(model, cUserContext("hello"), options).stopReason == .stop)
        #expect(server.requests.last?.headers.get("User-Agent") == "request/1")
        #expect(server.requests.last?.headers.get("x-opencode-client") == "acme")
        options.identity = nil
        #expect(await models.completeSimple(model, cUserContext("hello"), options).stopReason == .stop)
        #expect(server.requests.last?.headers.get("User-Agent") == "pi")
        wrapped.deleteProvider("custom")
        #expect(models.getProvider("custom") == nil)
    }
}
