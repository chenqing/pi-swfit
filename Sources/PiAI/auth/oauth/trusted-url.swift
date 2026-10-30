/// OAuth servers hand back URLs that get opened in the user's browser; only http(s) URLs are trusted.
public func trustedHttpUrl(_ value: JsonValue?) -> String? {
    guard case .string(let string)? = value, let url = WebURL(string) else { return nil }
    return url.protocol == "https:" || url.protocol == "http:" ? url.href : nil
}
