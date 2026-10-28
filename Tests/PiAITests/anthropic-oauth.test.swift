import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-oauth.test.ts
// `vi.stubGlobal("fetch", ...)` -> `createAnthropicOAuth(harness.runtime)`. The browser callback pages are
// requested with the real `defaultFetch`. The suite is serialized because it binds port 53692.

private let TOKEN_URL = "https://platform.claude.com/v1/oauth/token"

private func tokenResponse(_ access: String = "access-token", _ refresh: String = "refresh-token") -> FetchResponse {
    oauthJson(200, #"{"access_token":"\#(access)","refresh_token":"\#(refresh)","expires_in":3600}"#)
}

@Suite(.serialized) struct AnthropicOAuthTests {
    @Test func keepsTheLocalhostRedirectUriForManualCallbackLogin() async throws {
        let h = OAuthTestHarness { call in
            #expect(call.url == TOKEN_URL)
            #expect(call.method == "POST")
            let body = call.json
            #expect(body?["grant_type"] == "authorization_code")
            #expect(body?["code"] == "manual-code")
            #expect(body?["redirect_uri"] == "http://localhost:53692/callback")
            return tokenResponse()
        }
        // The prompt needs the auth URL from the notify event, so build the interaction by hand.
        let authUrl = Locked("")
        let credentials = try await createAnthropicOAuth(h.runtime).login(ProviderAuthInteraction(
            signal: AbortController().signal,
            prompt: { prompt in
                if prompt.type == "select" { return "browser" }
                if prompt.type != "manual_code" { throw PiError("Unexpected prompt: \(prompt.type)") }
                let url = WebURL(authUrl.current)!
                guard let state = url.searchParams.get("state"), let redirectUri = url.searchParams.get("redirect_uri") else {
                    throw PiError("Missing OAuth state or redirect_uri in auth URL")
                }
                return "\(redirectUri)?code=manual-code&state=\(state)"
            },
            notify: { event in if case .auth_url(let url, _) = event { authUrl.withLock { $0 = url } } }
        ), nil)

        #expect(credentials.access == "access-token")
        #expect(credentials.refresh == "refresh-token")
        #expect(h.calls.current.count == 1)
    }

    @Test func offersBrowserLoginFirstAndUsesTheSelectedAnthropicCopyCodeFlow() async throws {
        let selectPrompts = Locked<[AuthPrompt]>([])
        let authUrl = Locked("")
        let h = OAuthTestHarness { call in
            #expect(call.url == TOKEN_URL)
            let body = call.json
            #expect(body?["grant_type"] == "authorization_code")
            #expect(body?["code"] == "copied-code")
            #expect(body?["state"]?.stringValue == WebURL(authUrl.current)!.searchParams.get("state"))
            #expect(body?["redirect_uri"] == "https://platform.claude.com/oauth/code/callback")
            return tokenResponse()
        }
        let credentials = try await createAnthropicOAuth(h.runtime).login(ProviderAuthInteraction(
            signal: AbortController().signal,
            prompt: { prompt in
                if prompt.type == "select" {
                    selectPrompts.withLock { $0.append(prompt) }
                    return "copy_code"
                }
                if prompt.type != "manual_code" { throw PiError("Unexpected prompt: \(prompt.type)") }
                return "copied-code#\(WebURL(authUrl.current)!.searchParams.get("state") ?? "")"
            },
            notify: { event in if case .auth_url(let url, _) = event { authUrl.withLock { $0 = url } } }
        ), nil)

        #expect(credentials.access == "access-token")
        #expect(credentials.refresh == "refresh-token")
        #expect(WebURL(authUrl.current)!.searchParams.get("redirect_uri") == "https://platform.claude.com/oauth/code/callback")
        #expect(h.calls.current.count == 1)
        let prompts = selectPrompts.current
        #expect(prompts.count == 1)
        guard case .select(let message, let options) = prompts.first?.kind else {
            Issue.record("expected a select prompt")
            return
        }
        #expect(message == "Select Anthropic login method:")
        #expect(options.map(\.id) == ["browser", "copy_code"])
        #expect(options.map(\.label) == ["Browser login (default)", "Copy code login (headless)"])
    }

    @Test func cancelsWhenAnthropicLoginMethodSelectionIsCancelled() async throws {
        let h = OAuthTestHarness()
        let i = OAuthTestInteraction { _ in throw PiError("Login cancelled") }
        let error = await gCaught { _ = try await createAnthropicOAuth(h.runtime).login(i.interaction, nil) }
        #expect(errorMessage(error!) == "Login cancelled")
    }

    @Test func omitsScopeFromRefreshTokenRequests() async throws {
        let h = OAuthTestHarness { call in
            #expect(call.url == TOKEN_URL)
            #expect(call.method == "POST")
            let body = call.json?.objectValue
            #expect(body?["grant_type"] == "refresh_token")
            #expect((body?["client_id"]?.stringValue ?? "").isEmpty == false)
            #expect(body?["refresh_token"] == "refresh-token")
            #expect(body?["scope"] == nil)
            return tokenResponse("new-access-token", "new-refresh-token")
        }
        let credentials = try await createAnthropicOAuth(h.runtime).refresh(
            OAuthCredential(refresh: "refresh-token", access: "old-access-token", expires: 0),
            AbortController().signal
        )
        #expect(credentials.access == "new-access-token")
        #expect(credentials.refresh == "new-refresh-token")
        #expect(h.calls.current.count == 1)
    }

    @Test func loginResolvesThroughTheManualCodePromptAndAbortsItAfterSettling() async throws {
        let h = OAuthTestHarness { call in
            if call.url.contains("/oauth/token") { return tokenResponse("access", "refresh") }
            throw PiError("Unexpected fetch: \(call.url)")
        }
        let manualSignal = Locked<AbortSignal?>(nil)
        let i = OAuthTestInteraction { prompt in
            if prompt.type == "select" { return "browser" }
            if prompt.type == "manual_code" {
                manualSignal.withLock { $0 = prompt.signal }
                return "the-code"
            }
            throw PiError("Unexpected prompt: \(prompt.type)")
        }
        let credential = try await createAnthropicOAuth(h.runtime).login(i.interaction, nil)

        #expect(credential.access == "access")
        #expect(i.events.current.contains { $0.type == "auth_url" })
        #expect(i.prompts.current.contains { $0.type == "manual_code" })
        // the prompt's signal is aborted once login settles, so UIs can dismiss it
        #expect(manualSignal.current?.aborted == true)
    }

    @Test func completesLoginThroughTheBrowserCallbackAndShowsTheSignInPage() async throws {
        let login = try await loginThroughBrowserCallback()

        #expect(login.credential.access == "access")
        #expect(login.exchangedCode == "browser-code")
        #expect(login.exchangedRedirectUri == login.redirectUri)
        #expect(login.pageStatus == 200)
        #expect(login.pageText.contains("Signed in to Anthropic."))
    }

    // #10571
    @Test func fallsBackToAFreeCallbackPortWhenThePreferredPortCannotBeBound() async throws {
        let blocker = try await LoopbackHTTPServer.listen(host: "127.0.0.1", port: 53692) { _ in
            LoopbackHTTPResponse(status: 404, headers: [], body: "")
        }
        defer { blocker.close() }
        let login = try await loginThroughBrowserCallback()
        let redirectUri = WebURL(login.redirectUri)!

        #expect(redirectUri.hostname == "localhost")
        #expect(redirectUri.pathname == "/callback")
        #expect(redirectUri.port != "53692")
        #expect(login.credential.access == "access")
        #expect(login.exchangedRedirectUri == login.redirectUri)
        #expect(login.pageStatus == 200)
    }
}

private func loginThroughBrowserCallback() async throws -> (
    credential: OAuthCredential,
    redirectUri: String,
    exchangedCode: String?,
    exchangedRedirectUri: String?,
    pageStatus: Int?,
    pageText: String
) {
    let exchanged = Locked<(code: String?, redirectUri: String?)>((nil, nil))
    let h = OAuthTestHarness { call in
        let body = call.json
        exchanged.withLock { $0 = (body?["code"]?.stringValue, body?["redirect_uri"]?.stringValue) }
        return tokenResponse("access", "refresh")
    }

    let redirectUri = Locked("")
    let callbackPage = Locked<Task<(status: Int, contentType: String?, body: String), any Error>?>(nil)
    let credential = try await createAnthropicOAuth(h.runtime).login(ProviderAuthInteraction(
        signal: AbortController().signal,
        prompt: { prompt in
            prompt.type == "select" ? "browser" : try await oauthPendingPrompt(prompt)
        },
        notify: { event in
            guard case .auth_url(let url, _) = event else { return }
            let params = WebURL(url)!.searchParams
            let redirect = params.get("redirect_uri") ?? ""
            redirectUri.withLock { $0 = redirect }
            let port = WebURL(redirect)!.port
            let callbackUrl = WebURL("http://127.0.0.1:\(port)/callback")!.withSearch(URLSearchParams([
                ("code", "browser-code"),
                ("state", params.get("state") ?? ""),
            ]))
            callbackPage.withLock { $0 = Task { try await oauthLoopbackGet(callbackUrl.href) } }
        }
    ), nil)
    let page = try await callbackPage.current?.value
    return (
        credential,
        redirectUri.current,
        exchanged.current.code,
        exchanged.current.redirectUri,
        page?.status,
        page?.body ?? ""
    )
}
