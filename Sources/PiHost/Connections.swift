import Foundation
import Security
import LocalAuthentication
import CryptoKit
import PiAI

public protocol CredentialStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func remove(account: String) throws
}

/// Uses the user's login Keychain. No credentials are written into profiles or session files.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let allowInteraction: Bool
    public init(service: String = "dev.chenqing.pi-swift.connections", allowInteraction: Bool = true) {
        self.service = service; self.allowInteraction = allowInteraction
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    public func read(account: String) throws -> String? {
        var request = query(account)
        if !allowInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
        }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data, let key = String(data: data, encoding: .utf8) else { throw PiError("The saved credential is not valid UTF-8") }
        return key
    }
    public func write(_ secret: String, account: String) throws {
        let attributes = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = Data(secret.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    public func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed || (!allowInteraction && status == errSecAuthFailed) {
            throw PiError("Keychain access needs authorization. Run pf in an interactive terminal and approve its access, or unlock the login Keychain, then retry.")
        }
        guard status == errSecSuccess else {
            throw PiError("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
        }
    }
}

public struct ConnectionProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var modelID: String
    public var api: String
    public var endpoint: String
    public var provider: String
    /// Explicit capabilities for custom endpoints; nil uses an exact catalog match, otherwise off.
    public var thinkingLevels: [ModelThinkingLevel]?
    public init(id: String = UUID().uuidString, name: String, modelID: String, api: String,
                endpoint: String, provider: String = "custom", thinkingLevels: [ModelThinkingLevel]? = nil) {
        self.id = id; self.name = name; self.modelID = modelID; self.api = api
        self.endpoint = endpoint; self.provider = provider; self.thinkingLevels = thinkingLevels
    }
    // Scope credentials to both identity and destination. Editing a profile file cannot redirect a saved key.
    public var credentialAccount: String {
        let scope = id + "\n" + api + "\n" + endpoint + "\n" + provider
        return SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PiError("Enter a connection name and model ID") }
        guard ["openai-completions", "openai-responses", "anthropic-messages"].contains(api) else { throw PiError("Unsupported API format") }
        guard let url = URL(string: endpoint), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw PiError("Use an HTTPS endpoint, or HTTP on localhost, without credentials or query parameters")
        }
    }
    public func model() throws -> Model {
        try validate()
        var model = createModels().getModel(provider, modelID)
            ?? Model(id: modelID, name: name, api: api, provider: provider, baseUrl: endpoint,
                     input: ["text"], contextWindow: 128_000, maxTokens: 4096)
        model.name = name; model.api = api; model.provider = provider; model.baseUrl = endpoint
        if let thinkingLevels {
            guard !thinkingLevels.isEmpty else { throw PiError("Thinking levels must include at least one level") }
            model.reasoning = thinkingLevels.contains { $0 != .off }
            var map: ThinkingLevelMap = [:]
            for level in ModelThinkingLevel.allCases {
                map[level] = .some(thinkingLevels.contains(level) ? level.rawValue : nil)
            }
            model.thinkingLevelMap = map
        }
        return model
    }
}

public struct ConnectionCatalog: Codable, Sendable {
    public var profiles: [ConnectionProfile] = []
    public var defaultID: String?
    public init() {}
    public func profile(_ identifier: String? = nil) throws -> ConnectionProfile? {
        guard let identifier = identifier ?? defaultID else { return nil }
        let matches = profiles.filter { $0.id == identifier || $0.name == identifier }
        guard matches.count == 1 else { throw PiError("Connection not found or name is ambiguous: \(identifier)") }
        return matches[0]
    }
}

public struct ConnectionStore: Sendable {
    public let paths: HostPaths
    public let credentials: any CredentialStore
    public init(paths: HostPaths = .init(), credentials: any CredentialStore = KeychainCredentialStore()) {
        self.paths = paths; self.credentials = credentials
    }
    private var file: URL { URL(fileURLWithPath: paths.agentDir).appendingPathComponent("connections.json") }
    public func load() throws -> ConnectionCatalog {
        guard FileManager.default.fileExists(atPath: file.path) else { return ConnectionCatalog() }
        return try JSONDecoder().decode(ConnectionCatalog.self, from: Data(contentsOf: file))
    }
    public func save(_ profile: ConnectionProfile, apiKey: String?) throws {
        try profile.validate()
        let lock = try HostFileLock(file.path + ".lock")
        defer { lock.release() }
        var catalog = try load()
        // Immutable routing for existing identities; use a new profile when changing destinations.
        if let existing = catalog.profiles.first(where: { $0.id == profile.id }), existing.credentialAccount != profile.credentialAccount {
            throw PiError("Create a new connection to change its endpoint or API format")
        }
        if let apiKey { try credentials.write(apiKey, account: profile.credentialAccount) }
        catalog.profiles.removeAll { $0.id == profile.id }
        catalog.profiles.append(profile); catalog.defaultID = profile.id
        try writePrivateJSON(catalog, to: file)
    }
    public func key(for profile: ConnectionProfile) throws -> String? {
        try profile.validate()
        return try credentials.read(account: profile.credentialAccount)
    }
    public func forgetKey(for profile: ConnectionProfile) throws { try credentials.remove(account: profile.credentialAccount) }
}
