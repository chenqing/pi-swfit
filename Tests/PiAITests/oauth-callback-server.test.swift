import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/oauth-callback-server.test.ts
// Page requests use the real `defaultFetch` against the loopback server.

private func interaction(_ prompt: @escaping @Sendable (AuthPrompt) async throws -> String, signal: AbortSignal? = nil) -> ProviderAuthInteraction {
    ProviderAuthInteraction(signal: signal ?? AbortController().signal, prompt: prompt, notify: { _ in })
}

private func start(
    port: Int = 0,
    redirectHost: String? = nil,
    state: String? = "expected-state",
    complete: @escaping @Sendable (String) async throws -> String = { "completed:\($0)" },
    signal: AbortSignal? = nil,
    timeoutMs: Int? = nil
) async throws -> OAuthCallbackServer<String> {
    try await startOAuthCallbackServer(OAuthCallbackServerOptions<String>(
        providerName: "Example",
        host: "127.0.0.1",
        port: port,
        path: "/callback",
        redirectHost: redirectHost,
        state: state,
        complete: complete,
        signal: signal,
        timeoutMs: timeoutMs
    ))
}

@Suite(.serialized) struct OAuthCallbackServerTests {
    @Test func ignoresStrayRequestsAndResolvesWithTheCompletedCode() async throws {
        let server = try await start()
        defer { server.close() }
        #expect(server.redirectUri.wholeMatch(of: /http:\/\/127\.0\.0\.1:\d+\/callback/) != nil)

        let origin = WebURL(server.redirectUri)!.origin
        let wrongPath = try await oauthLoopbackGet(origin + "/other")
        #expect(wrongPath.status == 404)
        let wrongState = try await oauthLoopbackGet(oauthCallbackUrl(server.redirectUri, [("code", "c"), ("state", "other")]))
        #expect(wrongState.status == 400)
        #expect(wrongState.contentType == "text/html; charset=utf-8")
        #expect(wrongState.body.contains("State mismatch."))
        let post = try await oauthLoopbackGet(oauthCallbackUrl(server.redirectUri, [("code", "c"), ("state", "expected-state")]), method: "POST")
        #expect(post.status == 404)
        let missingCode = try await oauthLoopbackGet(oauthCallbackUrl(server.redirectUri, [("state", "expected-state")]))
        #expect(missingCode.status == 400)

        let success = try await oauthLoopbackGet(oauthCallbackUrl(server.redirectUri, [("code", "the-code"), ("state", "expected-state")]))
        #expect(success.status == 200)
        #expect(success.contentType == "text/html; charset=utf-8")
        #expect(success.body.contains("Authentication successful"))
        #expect(success.body.contains("Signed in to Example."))
        #expect(success.body.contains(##"fill="#F09082""##))
        #expect(success.body.contains(##"fill="#4D9ABF""##))
        #expect(success.body.contains(##"fill="#F1BE58""##))
        #expect(try await server.wait() == "completed:the-code")
    }

    @Test func usesTheRedirectHostAndSkipsTheStateCheckWhenNoneIsExpected() async throws {
        let server = try await start(redirectHost: "localhost", state: nil)
        defer { server.close() }
        #expect(server.redirectUri.wholeMatch(of: /http:\/\/localhost:\d+\/callback/) != nil)
        let port = WebURL(server.redirectUri)!.port
        let response = try await oauthLoopbackGet("http://127.0.0.1:\(port)/callback?code=no-state")
        #expect(response.status == 200)
        #expect(try await server.wait() == "completed:no-state")
    }

    @Test func showsCompletionFailuresOnThePageAndRejectsTheWait() async throws {
        let server = try await start(complete: { _ in throw PiError("token exchange failed") })
        defer { server.close() }
        let failure = try await oauthLoopbackGet(oauthCallbackUrl(server.redirectUri, [("code", "c"), ("state", "expected-state")]))
        #expect(failure.status == 502)
        #expect(failure.body.contains("Example sign-in failed."))
        #expect(failure.body.contains("token exchange failed"))
        let error = await gCaught { _ = try await server.wait() }
        #expect(errorMessage(error!) == "token exchange failed")
    }

    @Test func rejectsTheWaitWhenTheProviderRedirectsWithAnError() async throws {
        let server = try await start()
        defer { server.close() }
        let failure = try await oauthLoopbackGet(oauthCallbackUrl(server.redirectUri, [
            ("error", "access_denied"),
            ("error_description", "User denied access"),
            ("state", "expected-state"),
        ]))
        #expect(failure.status == 400)
        #expect(failure.body.contains("User denied access"))
        let error = await gCaught { _ = try await server.wait() }
        #expect(errorMessage(error!) == "Example authorization failed: User denied access")
    }

    @Test func completesOnlyTheFirstCallback() async throws {
        let entered = GGate()
        let finish = GGate()
        let server = try await start(complete: { _ in
            entered.open()
            await finish.wait()
            return "done"
        })
        defer { server.close() }
        let url = oauthCallbackUrl(server.redirectUri, [("code", "c"), ("state", "expected-state")])
        let first = Task { try await oauthLoopbackGet(url) }
        await entered.wait()
        let second = try await oauthLoopbackGet(url)
        #expect(second.status == 409)
        // A claimed callback keeps completing even when the caller switches to manual input.
        server.cancel()
        finish.open()
        #expect(try await first.value.status == 200)
        #expect(try await server.wait() == "done")
    }

    @Test func resolvesWithUndefinedAfterCancel() async throws {
        let server = try await start()
        defer { server.close() }
        server.cancel()
        #expect(try await server.wait() == nil)
        let late = try await oauthLoopbackGet(oauthCallbackUrl(server.redirectUri, [("code", "c"), ("state", "expected-state")]))
        #expect(late.status == 409)
    }

    @Test func rejectsTheWaitOnAbortAndOnTimeout() async throws {
        let controller = AbortController()
        let aborted = try await start(signal: controller.signal)
        defer { aborted.close() }
        controller.abort()
        let abortError = await gCaught { _ = try await aborted.wait() }
        #expect(errorMessage(abortError!) == "Login cancelled")

        let timedOut = try await start(timeoutMs: 10)
        defer { timedOut.close() }
        let timeoutError = await gCaught { _ = try await timedOut.wait() }
        #expect(errorMessage(timeoutError!) == "Example sign-in timed out")

        let alreadyAborted = AbortController()
        alreadyAborted.abort()
        let startError = await gCaught { _ = try await start(signal: alreadyAborted.signal) }
        #expect(errorMessage(startError!) == "Login cancelled")
    }

    @Test func failsInsteadOfPickingAnotherPortWhenTheRequestedPortIsTaken() async throws {
        let blocker = try await LoopbackHTTPServer.listen(host: "127.0.0.1", port: 0) { _ in
            LoopbackHTTPResponse(status: 404, headers: [], body: "")
        }
        defer { blocker.close() }
        let error = await gCaught { _ = try await start(port: blocker.port) }
        #expect((error as? LoopbackListenError)?.code == "EADDRINUSE")
    }
}

@Suite(.serialized) struct WaitForCallbackOrManualInputTests {
    private func plainServer() async throws -> OAuthCallbackServer<String> {
        try await startOAuthCallbackServer(OAuthCallbackServerOptions<String>(
            providerName: "Example",
            host: "127.0.0.1",
            port: 0,
            path: "/callback",
            complete: { $0 }
        ))
    }

    @Test func returnsTheBrowserCallbackAndAbortsTheManualPrompt() async throws {
        let manualSignal = Locked<AbortSignal?>(nil)
        let server = try await plainServer()
        defer { server.close() }
        let result = Task {
            try await waitForCallbackOrManualInput(
                interaction({ prompt in
                    manualSignal.withLock { $0 = prompt.signal }
                    return try await oauthPendingPrompt(prompt)
                }),
                server,
                message: "paste",
                placeholder: server.redirectUri
            )
        }
        _ = try await oauthLoopbackGet(oauthCallbackUrl(server.redirectUri, [("code", "from-browser")]))
        let value = try await result.value
        guard case .callback(let code) = value else {
            Issue.record("expected callback, got \(value)")
            return
        }
        #expect(code == "from-browser")
        #expect(manualSignal.current?.aborted == true)
    }

    @Test func returnsPastedInputAndStopsWaitingForTheBrowser() async throws {
        let server = try await plainServer()
        defer { server.close() }
        let result = try await waitForCallbackOrManualInput(
            interaction({ _ in "pasted" }),
            server,
            message: "paste",
            placeholder: server.redirectUri
        )
        guard case .manual(let input) = result else {
            Issue.record("expected manual, got \(result)")
            return
        }
        #expect(input == "pasted")
    }

    @Test func usesOnlyTheManualPromptWithoutACallbackServer() async throws {
        let result = try await waitForCallbackOrManualInput(
            interaction({ _ in "pasted" }),
            OAuthCallbackServer<String>?.none,
            message: "paste",
            placeholder: "http://localhost/callback"
        )
        guard case .manual(let input) = result else {
            Issue.record("expected manual, got \(result)")
            return
        }
        #expect(input == "pasted")
    }

    @Test func propagatesManualPromptFailures() async throws {
        let server = try await plainServer()
        defer { server.close() }
        let error = await gCaught {
            _ = try await waitForCallbackOrManualInput(
                interaction({ _ in throw PiError("prompt cancelled") }),
                server,
                message: "paste",
                placeholder: server.redirectUri
            )
        }
        #expect(errorMessage(error!) == "prompt cancelled")
    }
}
