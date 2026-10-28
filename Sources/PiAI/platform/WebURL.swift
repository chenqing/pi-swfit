import Foundation

// Swift-only: the subset of the WHATWG `URL` / `URLSearchParams` APIs the OAuth flows use.
//
// Foundation's `URLComponents` follows RFC 3986 and rejects inputs that `new URL()` accepts (raw control
// characters, `]` in paths, ...), and its `href` differs from WHATWG serialization. The OAuth flows validate
// and normalize provider-supplied URLs with `new URL(x).href`, so the parts that matter are ported here:
// scheme detection, special-scheme authority parsing (lower-cased host, default-port removal, `/` path),
// percent-encoding of path/query/fragment, `origin`, `pathname`, and `searchParams`.
// Not ported: IDNA host processing, dot-segment path normalization, relative URL resolution.

/// `new URL(input)`; `nil` where the constructor throws.
struct WebURL: Sendable, CustomStringConvertible {
    /// Lower-cased scheme without the trailing `:`.
    let scheme: String
    /// Host as WHATWG serializes it (lower-cased for special schemes); "" when absent.
    let hostname: String
    /// Port without the default port of the scheme; "" when absent.
    let port: String
    /// Whether the URL has an authority (`//host`).
    let hasAuthority: Bool
    let userinfo: String?
    /// Percent-encoded path.
    let pathname: String
    /// Percent-encoded query without `?`; nil when there is no `?`.
    let query: String?
    /// Percent-encoded fragment without `#`; nil when there is no `#`.
    let fragment: String?

    private static let specialSchemes: [String: String?] = [
        "http": "80", "https": "443", "ws": "80", "wss": "443", "ftp": "21", "file": nil,
    ]

    init?(_ rawInput: String) {
        // Strip leading/trailing C0 control or space, then remove ASCII tab or newline.
        var scalars = Array(rawInput.unicodeScalars)
        while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
        while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
        scalars.removeAll { $0 == "\t" || $0 == "\n" || $0 == "\r" }
        var input = String(String.UnicodeScalarView(scalars))

        // Scheme.
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let schemePart = input[input.startIndex..<colon]
        guard let firstScalar = schemePart.unicodeScalars.first, firstScalar.isASCIILetter,
              schemePart.unicodeScalars.allSatisfy({ $0.isASCIILetter || $0.isASCIIDigit || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        let scheme = schemePart.lowercased()
        input = String(input[input.index(after: colon)...])

        // Fragment and query.
        var fragment: String?
        if let hash = input.firstIndex(of: "#") {
            fragment = String(input[input.index(after: hash)...])
            input = String(input[..<hash])
        }
        var query: String?
        if let question = input.firstIndex(of: "?") {
            query = String(input[input.index(after: question)...])
            input = String(input[..<question])
        }

        let isSpecial = Self.specialSchemes.keys.contains(scheme)
        var hostname = ""
        var port = ""
        var userinfo: String?
        var hasAuthority = false
        var path: String

        if isSpecial || input.hasPrefix("//") {
            if isSpecial {
                while let first = input.first, first == "/" || first == "\\" { input.removeFirst() }
            } else {
                input.removeFirst(2)
            }
            hasAuthority = true
            let authorityEnd = input.firstIndex { $0 == "/" || (isSpecial && $0 == "\\") } ?? input.endIndex
            var authority = String(input[..<authorityEnd])
            path = String(input[authorityEnd...])
            if isSpecial { path = path.replacingOccurrences(of: "\\", with: "/") }
            if let at = authority.lastIndex(of: "@") {
                userinfo = String(authority[..<at])
                authority = String(authority[authority.index(after: at)...])
            }
            var hostPart = authority
            if authority.hasPrefix("[") {
                guard let close = authority.firstIndex(of: "]") else { return nil }
                hostPart = String(authority[...close])
                let after = authority[authority.index(after: close)...]
                if after.hasPrefix(":") { port = String(after.dropFirst()) } else if !after.isEmpty { return nil }
            } else if let portColon = authority.lastIndex(of: ":") {
                hostPart = String(authority[..<portColon])
                port = String(authority[authority.index(after: portColon)...])
            }
            guard port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            if !port.isEmpty {
                guard let value = Int(port), value <= 65535 else { return nil }
                port = String(value)
                if let defaultPort = Self.specialSchemes[scheme], defaultPort == port { port = "" }
            }
            let forbidden: Set<Character> = [" ", "#", "%", "/", ":", "<", ">", "?", "@", "[", "\\", "]", "^", "|"]
            if !hostPart.hasPrefix("[") {
                if hostPart.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return nil }
                if hostPart.contains(where: { forbidden.contains($0) }) { return nil }
            }
            if isSpecial { hostPart = hostPart.lowercased() }
            if isSpecial && scheme != "file" && hostPart.isEmpty { return nil }
            hostname = hostPart
            if isSpecial && path.isEmpty { path = "/" }
        } else {
            path = input
        }

        self.scheme = scheme
        self.hostname = hostname
        self.port = port
        self.hasAuthority = hasAuthority
        self.userinfo = userinfo
        self.pathname = Self.percentEncode(path, extra: hasAuthority ? ["\"", "#", "<", ">", "?", "`", "{", "}"] : ["\"", "<", ">", "`"])
        self.query = query.map { Self.percentEncode($0, extra: isSpecial ? ["\"", "#", "<", ">", "'"] : ["\"", "#", "<", ">"]) }
        self.fragment = fragment.map { Self.percentEncode($0, extra: ["\"", "<", ">", "`"]) }
    }

    /// Percent-encode C0 controls, space, non-ASCII and `extra`; existing escapes are kept.
    private static func percentEncode(_ value: String, extra: Set<Character>) -> String {
        let extra = Set(extra.compactMap(\.asciiValue))
        var output = ""
        for byte in value.utf8 {
            if byte <= 0x20 || byte >= 0x7F || extra.contains(byte) {
                output += String(format: "%%%02X", byte)
            } else {
                output.unicodeScalars.append(UnicodeScalar(byte))
            }
        }
        return output
    }

    var `protocol`: String { scheme + ":" }

    /// `host`: hostname plus non-default port.
    var host: String { port.isEmpty ? hostname : "\(hostname):\(port)" }

    var origin: String {
        guard Self.specialSchemes.keys.contains(scheme), scheme != "file" else { return "null" }
        return "\(scheme)://\(host)"
    }

    /// `search`: `?query`, or "" when the query is absent or empty.
    var search: String {
        guard let query, !query.isEmpty else { return "" }
        return "?" + query
    }

    var searchParams: URLSearchParams { URLSearchParams(query ?? "") }

    var href: String {
        var result = scheme + ":"
        if hasAuthority {
            result += "//"
            if let userinfo, !userinfo.isEmpty { result += userinfo + "@" }
            result += host
        }
        result += pathname
        if let query { result += "?" + query }
        if let fragment { result += "#" + fragment }
        return result
    }

    var description: String { href }

    /// Replace the query with the serialization of `params` (`url.search = params.toString()`).
    func withSearch(_ params: URLSearchParams) -> WebURL {
        let serialized = params.toString()
        return WebURL(
            scheme: scheme, hostname: hostname, port: port, hasAuthority: hasAuthority, userinfo: userinfo,
            pathname: pathname, query: serialized.isEmpty ? nil : serialized, fragment: fragment
        )
    }

    /// `url.pathname = value` (the value is percent-encoded like a parsed path).
    func withPathname(_ value: String) -> WebURL {
        var path = value
        if Self.specialSchemes.keys.contains(scheme) && !path.hasPrefix("/") { path = "/" + path }
        return WebURL(
            scheme: scheme, hostname: hostname, port: port, hasAuthority: hasAuthority, userinfo: userinfo,
            pathname: Self.percentEncode(path, extra: hasAuthority ? ["\"", "#", "<", ">", "?", "`", "{", "}"] : ["\"", "<", ">", "`"]),
            query: query, fragment: fragment
        )
    }

    private init(scheme: String, hostname: String, port: String, hasAuthority: Bool, userinfo: String?, pathname: String, query: String?, fragment: String?) {
        self.scheme = scheme; self.hostname = hostname; self.port = port; self.hasAuthority = hasAuthority
        self.userinfo = userinfo; self.pathname = pathname; self.query = query; self.fragment = fragment
    }
}

/// `URLSearchParams` (application/x-www-form-urlencoded).
struct URLSearchParams: Sendable, Sequence {
    private(set) var entries: [(name: String, value: String)] = []

    init(_ pairs: KeyValuePairs<String, String>) {
        for (name, value) in pairs { entries.append((name, value)) }
    }

    init(_ pairs: [(String, String)]) {
        for (name, value) in pairs { entries.append((name, value)) }
    }

    /// `new URLSearchParams(string)`: parses a query string (a leading `?` is ignored).
    init(_ query: String) {
        var query = Substring(query)
        if query.hasPrefix("?") { query = query.dropFirst() }
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let name: Substring
            let value: Substring
            if let equals = part.firstIndex(of: "=") {
                name = part[..<equals]
                value = part[part.index(after: equals)...]
            } else {
                name = part
                value = ""
            }
            entries.append((Self.decode(name), Self.decode(value)))
        }
    }

    func get(_ name: String) -> String? { entries.first { $0.name == name }?.value }
    func has(_ name: String) -> Bool { entries.contains { $0.name == name } }

    mutating func set(_ name: String, _ value: String) {
        guard let index = entries.firstIndex(where: { $0.name == name }) else {
            entries.append((name, value))
            return
        }
        entries[index].value = value
        var seen = false
        entries.removeAll { entry in
            guard entry.name == name else { return false }
            if !seen { seen = true; return false }
            return true
        }
    }

    mutating func append(_ name: String, _ value: String) { entries.append((name, value)) }

    func makeIterator() -> IndexingIterator<[(name: String, value: String)]> { entries.makeIterator() }

    func toString() -> String {
        entries.map { Self.encode($0.name) + "=" + Self.encode($0.value) }.joined(separator: "&")
    }

    /// application/x-www-form-urlencoded byte serializer.
    static func encode(_ value: String) -> String {
        var output = ""
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2A, 0x2D, 0x2E, 0x5F:
                output.unicodeScalars.append(UnicodeScalar(byte))
            case 0x20:
                output += "+"
            default:
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }

    /// application/x-www-form-urlencoded parser for one name or value.
    static func decode<S: StringProtocol>(_ value: S) -> String {
        let bytes = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x2B {
                output.append(0x20)
            } else if byte == 0x25, index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 2
            } else {
                output.append(byte)
            }
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

private extension Unicode.Scalar {
    var isASCIILetter: Bool { (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) }
    var isASCIIDigit: Bool { (0x30...0x39).contains(value) }
}
