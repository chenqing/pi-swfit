import CryptoKit
import Foundation

// Port of packages/ai/src/auth/oauth/pkce.ts

/**
 * PKCE utilities using Web Crypto API.
 * Works in both Node.js 20+ and browsers.
 */

/**
 * Encode bytes as base64url string.
 */
func base64urlEncode<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/**
 * Generate PKCE code verifier and challenge.
 * Uses Web Crypto API for cross-platform compatibility.
 */
public func generatePKCE() async -> (verifier: String, challenge: String) {
    // Generate random verifier
    var generator = SystemRandomNumberGenerator()
    let verifierBytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let verifier = base64urlEncode(verifierBytes)

    // Compute SHA-256 challenge
    let data = Data(verifier.utf8)
    let hashBuffer = SHA256.hash(data: data)
    let challenge = base64urlEncode(hashBuffer)

    return (verifier: verifier, challenge: challenge)
}
