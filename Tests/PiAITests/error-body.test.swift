// Unit tests for the shared provider error-body normalizer.
//
// See issues/provider-error-body-passthrough. These cover one synthesized error
// object per SDK shape (Mistral, openai APIError, @google/genai ApiError, AWS
// Bedrock ServiceException), plus the non-Error fallback, truncation, the empty
// parsed-body edge case, and the formatProviderError compose helper.
//
// Swift: `Object.assign(new Error(message), {...})` -> `ProviderSdkError(message, ...)`.
// Class instances -> `SdkErrorField.instance`; objects with `pipe()` -> `SdkErrorField.stream`.

import Foundation
import Testing
@testable import PiAI

@Suite
struct ErrorBodyTests {
    // MARK: normalizeProviderError

    @Test("extracts status and body from a Mistral-shaped error")
    func mistralShaped() {
        let error = ProviderSdkError("Mistral request failed", statusCode: 403, body: .value("{\"error\":\"blocked by gateway WAF\"}"))

        let norm = normalizeProviderError(error)

        #expect(norm.status == 403)
        #expect(norm.body == "{\"error\":\"blocked by gateway WAF\"}")
        #expect(norm.messageCarriesBody == false)
    }

    @Test("reads the parsed body off an openai APIError when the message is opaque")
    func openaiOpaque() {
        // makeMessage(status, error, message) yields "<status> status code (no body)"
        // when the parsed body is unparsed, while the body stays on error.error.
        let error = ProviderSdkError("403 status code (no body)", status: 403, error: .value(["error": "blocked by gateway WAF"]))

        let norm = normalizeProviderError(error)

        #expect(norm.status == 403)
        #expect(norm.body == "{\"error\":\"blocked by gateway WAF\"}")
        #expect(norm.messageCarriesBody == false)
    }

    @Test("preserves the message when @google/genai already folds the body into it")
    func googleFolded() {
        let body: JsonValue = ["error": ["code": 403, "message": "Permission denied"]]
        let error = ProviderSdkError(body.serialized(), status: 403)

        let norm = normalizeProviderError(error)

        #expect(norm.status == 403)
        #expect(norm.messageCarriesBody == true)
        #expect(norm.message == body.serialized())
    }

    @Test("extracts status and body from a Bedrock-shaped ServiceException")
    func bedrockShaped() {
        let error = ProviderSdkError(
            "UnknownError",
            name: "UnknownError",
            metadataHttpStatusCode: 403,
            responseStatusCode: 403,
            responseBody: .value("{\"message\":\"blocked by gateway WAF\"}")
        )

        let norm = normalizeProviderError(error)

        #expect(norm.status == 403)
        #expect(norm.body == "{\"message\":\"blocked by gateway WAF\"}")
        #expect(norm.messageCarriesBody == false)
    }

    @Test("ignores a Bedrock response stream instead of serializing its internals")
    func bedrockStream() {
        let error = ProviderSdkError(
            "Invocation of model ID anthropic.claude-opus-5 with on-demand throughput isn't supported.",
            name: "ValidationException",
            metadataHttpStatusCode: 400,
            responseStatusCode: 400,
            responseBody: .stream
        )

        let norm = normalizeProviderError(error)

        #expect(norm.status == 400)
        #expect(norm.body == nil)
        #expect(norm.message.contains("on-demand throughput isn't supported"))
        #expect(norm.messageCarriesBody == true)
    }

    @Test("ignores a class-instance response body without a pipe method instead of serializing it")
    func classInstanceResponseBody() {
        // Not every SDK response wrapper is a node stream: web ReadableStreams
        // and SDK-specific wrapper classes have no `pipe`, but serializing them
        // still yields internals-noise that would replace the real message.
        let error = ProviderSdkError(
            "Input is too long for requested model.",
            name: "ValidationException",
            metadataHttpStatusCode: 400,
            responseStatusCode: 400,
            responseBody: .instance
        )

        let norm = normalizeProviderError(error)

        #expect(norm.status == 400)
        #expect(norm.body == nil)
        #expect(norm.message.contains("Input is too long"))
        #expect(norm.messageCarriesBody == true)
    }

    @Test("ignores a class-instance `error` field instead of serializing it")
    func classInstanceErrorField() {
        let error = ProviderSdkError("TLS handshake failed", status: 502, error: .instance)

        let norm = normalizeProviderError(error)

        #expect(norm.body == nil)
        #expect(norm.message == "TLS handshake failed")
        #expect(norm.messageCarriesBody == true)
    }

    @Test("still surfaces a plain parsed JSON body object")
    func plainParsedBody() {
        let error = ProviderSdkError(
            "400 status code (no body)",
            status: 400,
            error: .value(["message": "schema validation failed", "field": "tools[0]"])
        )

        let norm = normalizeProviderError(error)

        #expect(norm.body == "{\"message\":\"schema validation failed\",\"field\":\"tools[0]\"}")
        #expect(norm.messageCarriesBody == false)
    }

    @Test("JSON-stringifies a non-Error thrown value")
    func nonErrorValue() {
        let norm = normalizeProviderError(nonError: ["reason": "boom"])

        #expect(norm.status == nil)
        #expect(norm.body == nil)
        #expect(norm.message == "{\"reason\":\"boom\"}")
        #expect(norm.messageCarriesBody == false)
    }

    @Test("treats an empty parsed body object as no body")
    func emptyParsedBody() {
        let error = ProviderSdkError("403 status code (no body)", status: 403, error: .value(.object(JsonObject())))

        let norm = normalizeProviderError(error)

        #expect(norm.body == nil)
        #expect(norm.messageCarriesBody == true)
    }

    @Test("truncates the body at the cap")
    func truncates() {
        let longBody = String(repeating: "x", count: MAX_PROVIDER_ERROR_BODY_CHARS + 50)
        let error = ProviderSdkError("failed", statusCode: 500, body: .value(.string(longBody)))

        let norm = normalizeProviderError(error)

        #expect(norm.body?.contains("... [truncated 50 chars]") == true)
        #expect((norm.body?.count ?? Int.max) < longBody.count)
    }

    @Test("sets messageCarriesBody when the message already contains the extracted body")
    func messageContainsBody() {
        let error = ProviderSdkError("500: upstream exploded", statusCode: 500, body: .value("upstream exploded"))

        let norm = normalizeProviderError(error)

        #expect(norm.messageCarriesBody == true)
    }

    // MARK: formatProviderError

    @Test("surfaces status and body without a prefix")
    func formatNoPrefix() {
        let norm = normalizeProviderError(
            ProviderSdkError("403 status code (no body)", status: 403, error: .value(["error": "blocked by gateway WAF"]))
        )

        let formatted = formatProviderError(norm)

        #expect(formatted.contains("403"))
        #expect(formatted.contains("blocked by gateway WAF"))
        #expect(formatted != "403 status code (no body)")
    }

    @Test("applies a provider prefix with status and body")
    func formatWithPrefix() {
        let norm = normalizeProviderError(
            ProviderSdkError("403 status code (no body)", status: 403, error: .value(["error": "blocked by gateway WAF"]))
        )

        #expect(formatProviderError(norm, "OpenAI API error") == "OpenAI API error (403): {\"error\":\"blocked by gateway WAF\"}")
    }

    @Test("preserves the message (with prefix + status) when it already carries the body")
    func formatPreservesMessage() {
        let body = JsonValue.object(["error": ["message": "Permission denied"]]).serialized()
        let norm = normalizeProviderError(ProviderSdkError(body, status: 403))

        #expect(formatProviderError(norm, "OpenAI API error") == "OpenAI API error (403): \(body)")
    }

    @Test("returns the bare message for a non-Error value")
    func formatNonError() {
        let norm = normalizeProviderError(nonError: ["reason": "boom"])

        #expect(formatProviderError(norm) == "{\"reason\":\"boom\"}")
    }
}
