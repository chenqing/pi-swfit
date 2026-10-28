import CryptoKit
import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openrouter-oauth.test.ts
// `vi.stubGlobal("fetch", ...)` / `vi.stubEnv(...)` -> `createOpenRouterOAuth(harness.runtime)`. Callback
// pages are requested with the real `defaultFetch`, so the harness only sees the key exchange.
// Prompts that never resolve upstream (`new Promise(() => {})`) wait for their signal here, so no
// continuation leaks when the flow aborts the manual prompt.
// Not ported: "resolves the same stored OAuth key for chat and image models" (image models and the
// generated OpenRouter catalog are not ported).

private let TOKEN_URL = "https://openrouter.ai/api/v1/auth/keys"

private func base64url(_ bytes: some Sequence<UInt8>) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// `notify` that requests the loopback callback with `code` once the auth URL is announced.
private final class CallbackDriver: Sendable {
    let authorizeUrl = Locked<WebURL?>(nil)
    let callbackUrl = Locked<String?>(nil)
    let page = Locked<Task<(status: Int, contentType: String?, body: String), any Error>?>(nil)
    let code: String?
    let onAuthUrl: (@Sendable () -> Void)?

    init(code: String?, onAuthUrl: (@Sendable () -> Void)? = nil) {
        self.code = code
        self.onAuthUrl = onAuthUrl
    }

    func notify(_ event: AuthEvent) {
        guard case .auth_url(let url, _) = event else { return }
        let authorize = WebURL(url)!
        authorizeUrl.withLock { $0 = authorize }
        let callback = authorize.searchParams.get("callback_url") ?? ""
        let target = code.map { oauthCallbackUrl(callback, [("code", $0)]) } ?? callback
        callbackUrl.withLock { $0 = target }
        if code != nil {
            page.withLock { $0 = Task { try await oauthLoopbackGet(target) } }
        }
        onAuthUrl?()
    }

    var pageStatus: Int? {
        get async { try? await page.current?.value.status }
    }
}

@Suite(.serialized) struct OpenRouterOAuthTests {
    @Test func isExposedAlongsideApiKeyAuth() {
        let provider = openrouterProvider()
        #expect(provider.auth.apiKey != nil)
        #expect(provider.auth.oauth != nil)
        #expect(provider.auth.oauth?.loginLabel == "Sign in with OpenRouter")
    }

    @Test func runsPkceOnAOneShotLoopbackCallbackAndExchangesTheCodeForAPermanentApiKey() async throws {
        let h = OAuthTestHarness { call in
            #expect(call.url == TOKEN_URL)
            return oauthJson(200, #"{"key":"sk-or-test"}"#)
        }
        let driver = CallbackDriver(code: "authorization-code")
        let manualSignal = Locked<AbortSignal?>(nil)
        let credential = try await createOpenRouterOAuth(h.runtime).login(ProviderAuthInteraction(
            signal: AbortController().signal,
            prompt: { prompt in
                manualSignal.withLock { $0 = prompt.signal }
                return try await oauthPendingPrompt(prompt)
            },
            notify: driver.notify
        ), nil)

        #expect(credential.access == "sk-or-test")
        #expect(credential.refresh == "")
        #expect(credential.expires == 9_007_199_254_740_991)
        #expect(credential.extra.isEmpty)
        #expect(await driver.pageStatus == 200)
        #expect(manualSignal.current?.aborted == true)
        let authorizeUrl = try #require(driver.authorizeUrl.current)
        #expect(authorizeUrl.origin == "https://openrouter.ai")
        #expect(authorizeUrl.pathname == "/auth")
        #expect(authorizeUrl.searchParams.get("code_challenge_method") == "S256")

        let callbackUrl = try #require(WebURL(authorizeUrl.searchParams.get("callback_url") ?? ""))
        #expect(callbackUrl.hostname == "127.0.0.1")
        #expect(callbackUrl.pathname.wholeMatch(of: /\/oauth\/callback\/[0-9a-f-]+/) != nil)

        let exchangeBody = try #require(h.calls.current.first?.json)
        #expect(exchangeBody["code"] == "authorization-code")
        #expect(exchangeBody["code_challenge_method"] == "S256")
        let verifier = try #require(exchangeBody["code_verifier"]?.stringValue)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        #expect(authorizeUrl.searchParams.get("code_challenge") == base64url(digest))
        #expect(h.calls.current.count == 1)
    }

    @Test func reportsTokenExchangeFailuresThroughBothTheCallbackPageAndLogin() async throws {
        let h = OAuthTestHarness { _ in oauthJson(403, #"{"error":{"message":"invalid code"}}"#) }
        let driver = CallbackDriver(code: "bad-code")
        let error = await gCaught {
            _ = try await createOpenRouterOAuth(h.runtime).login(ProviderAuthInteraction(
                signal: AbortController().signal,
                prompt: oauthPendingPrompt,
                notify: driver.notify
            ), nil)
        }
        #expect(errorMessage(error!) == "OpenRouter OAuth key exchange failed (HTTP 403): invalid code")
        #expect(await driver.pageStatus == 502)
    }

    @Test func allowsOnlyOneTokenExchangeForACallback() async throws {
        let started = GGate()
        let release = GGate()
        let h = OAuthTestHarness { _ in
            started.open()
            await release.wait()
            return oauthJson(200, #"{"key":"sk-or-test"}"#)
        }
        let driver = CallbackDriver(code: "authorization-code")
        let login = Task {
            try await createOpenRouterOAuth(h.runtime).login(ProviderAuthInteraction(
                signal: AbortController().signal,
                prompt: oauthPendingPrompt,
                notify: driver.notify
            ), nil)
        }

        await started.wait()
        #expect(h.calls.current.count == 1)
        let callbackUrl = try #require(driver.callbackUrl.current)
        #expect(try await oauthLoopbackGet(callbackUrl).status == 409)
        #expect(h.calls.current.count == 1)
        release.open()

        #expect(try await login.value.access == "sk-or-test")
        #expect(await driver.pageStatus == 200)
    }

    @Test func rejectsASuccessfulResponseThatDoesNotContainAKey() async throws {
        let h = OAuthTestHarness { _ in oauthJson(200, #"{"user_id":"user-1"}"#) }
        let driver = CallbackDriver(code: "code-without-key")
        let error = await gCaught {
            _ = try await createOpenRouterOAuth(h.runtime).login(ProviderAuthInteraction(
                signal: AbortController().signal,
                prompt: oauthPendingPrompt,
                notify: driver.notify
            ), nil)
        }
        #expect(errorMessage(error!) == #"OpenRouter OAuth response carries no "key""#)
        #expect(await driver.pageStatus == 502)
    }

    @Test func mintsAKeyFromAPastedRedirectUrlWhenTheLoopbackCallbackNeverArrives() async throws {
        let h = OAuthTestHarness { call in
            #expect(call.url == TOKEN_URL)
            return oauthJson(200, #"{"key":"sk-or-manual"}"#)
        }
        let driver = CallbackDriver(code: nil)
        let credential = try await createOpenRouterOAuth(h.runtime).login(ProviderAuthInteraction(
            signal: AbortController().signal,
            prompt: { prompt in
                if prompt.type != "manual_code" { throw PiError("Unexpected prompt: \(prompt.type)") }
                return "\(driver.callbackUrl.current ?? "")?code=manual-code"
            },
            notify: driver.notify
        ), nil)

        #expect(credential.access == "sk-or-manual")
        #expect(credential.refresh == "")
        #expect(credential.expires == 9_007_199_254_740_991)
        let exchangeBody = try #require(h.calls.current.first?.json)
        #expect(exchangeBody["code"] == "manual-code")
        #expect(exchangeBody["code_challenge_method"] == "S256")
        #expect(h.calls.current.count == 1)
    }

    @Test func acceptsABareAuthorizationCodeFromTheManualPrompt() async throws {
        let h = OAuthTestHarness { _ in oauthJson(200, #"{"key":"sk-or-manual"}"#) }
        let i = OAuthTestInteraction { _ in "  manual-code  " }
        let credential = try await createOpenRouterOAuth(h.runtime).login(i.interaction, nil)

        #expect(credential.access == "sk-or-manual")
        #expect(h.calls.current.first?.json?["code"] == "manual-code")
    }

    @Test func failsLoginWhenTheManualPromptIsCancelled() async throws {
        let h = OAuthTestHarness { _ in oauthJson(200, #"{"key":"sk-or-unexpected"}"#) }
        let i = OAuthTestInteraction { _ in throw PiError("Login cancelled") }
        let error = await gCaught { _ = try await createOpenRouterOAuth(h.runtime).login(i.interaction, nil) }
        #expect(errorMessage(error!) == "Login cancelled")
        #expect(h.calls.current.isEmpty)
    }

    @Test func rejectsEmptyManualInputWithoutExchangingACode() async throws {
        let h = OAuthTestHarness { _ in oauthJson(200, #"{"key":"sk-or-unexpected"}"#) }
        let i = OAuthTestInteraction { _ in "   " }
        let error = await gCaught { _ = try await createOpenRouterOAuth(h.runtime).login(i.interaction, nil) }
        #expect(errorMessage(error!) == "Missing authorization code")
        #expect(h.calls.current.isEmpty)
    }

    @Test func closesThePendingCallbackWhenLoginIsCancelled() async throws {
        let controller = AbortController()
        let driver = CallbackDriver(code: nil, onAuthUrl: { controller.abort() })
        let h = OAuthTestHarness()
        let error = await gCaught {
            _ = try await createOpenRouterOAuth(h.runtime).login(ProviderAuthInteraction(
                signal: controller.signal,
                prompt: oauthPendingPrompt,
                notify: driver.notify
            ), nil)
        }
        #expect(errorMessage(error!) == "Login cancelled")
        let callbackUrl = try #require(driver.callbackUrl.current)
        let fetchError = await gCaught { _ = try await oauthLoopbackGet(callbackUrl) }
        #expect(fetchError != nil)
    }

    @Test func rejectsBeforeOpeningACallbackServerWhenLoginIsAlreadyCancelled() async throws {
        let controller = AbortController()
        controller.abort()
        let h = OAuthTestHarness()
        let notified = Locked(false)
        let error = await gCaught {
            _ = try await createOpenRouterOAuth(h.runtime).login(ProviderAuthInteraction(
                signal: controller.signal,
                prompt: { _ in "" },
                notify: { _ in notified.withLock { $0 = true } }
            ), nil)
        }
        #expect(errorMessage(error!) == "Login cancelled")
        #expect(notified.current == false, "Cancelled login must not emit events")
    }

    @Test func usesTheConfiguredOAuthCallbackHost() async throws {
        let h = OAuthTestHarness(env: ["PI_OAUTH_CALLBACK_HOST": "localhost"])
        let controller = AbortController()
        let driver = CallbackDriver(code: nil, onAuthUrl: { controller.abort() })
        let error = await gCaught {
            _ = try await createOpenRouterOAuth(h.runtime).login(ProviderAuthInteraction(
                signal: controller.signal,
                prompt: oauthPendingPrompt,
                notify: driver.notify
            ), nil)
        }
        #expect(errorMessage(error!) == "Login cancelled")
        #expect(WebURL(driver.callbackUrl.current ?? "")?.hostname == "localhost")
    }
}
