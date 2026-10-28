import Foundation

// Port of packages/ai/src/api/openai-prompt-cache.ts

public let OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH = 64

public func clampOpenAIPromptCacheKey(_ key: String?) -> String? {
    guard let key else { return nil }
    // `Array.from(key)` iterates code points.
    let chars = Array(key.unicodeScalars)
    if chars.count <= OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH { return key }
    var result = String.UnicodeScalarView()
    result.append(contentsOf: chars.prefix(OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH))
    return String(result)
}
