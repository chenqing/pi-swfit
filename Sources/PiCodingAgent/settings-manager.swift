import Foundation
import PiAI

// Port of core/settings-manager.ts and settings-schema.ts. Original compaction/retry baseline
// 16f5f0af4; scoped storage, migrations and resource settings aligned with 42cb822f1c5d3153069dd0661bfd297424666cf1.
// Swift: writes are synchronous, locked and atomic, so there is no pending write queue to flush.
// Not ported: typed accessors for provider/UI/package settings (unknown fields are preserved),
// and persisted project trust decisions.

// MARK: - settings-schema.ts (subset)

/// `Settings` (subset). Field names and nesting follow upstream `settings.json`.
public struct Settings: Sendable, Hashable, Codable {
    /// `CompactionModelOverride`. Token values are JS numbers upstream; `Double` keeps invalid
    /// runtime values (fractions, negatives, NaN, Infinity) reportable as upstream does.
    public struct CompactionModelOverride: Sendable, Hashable, Codable {
        public var enabled: Bool?
        public var reserveTokens: Double?
        public var keepRecentTokens: Double?
        public init(enabled: Bool? = nil, reserveTokens: Double? = nil, keepRecentTokens: Double? = nil) {
            self.enabled = enabled; self.reserveTokens = reserveTokens; self.keepRecentTokens = keepRecentTokens
        }
    }

    /// `CompactionSettings` (settings-schema). Swift: nested to avoid clashing with the resolved
    /// `CompactionSettings` of compaction.ts.
    public struct CompactionSettings: Sendable, Hashable, Codable {
        public var enabled: Bool? // default: true
        public var reserveTokens: Double? // default: 16384
        public var keepRecentTokens: Double? // default: 20000
        /** Exact `provider/model-id` keys. */
        public var modelOverrides: [String: CompactionModelOverride]?
        public init(enabled: Bool? = nil, reserveTokens: Double? = nil, keepRecentTokens: Double? = nil, modelOverrides: [String: CompactionModelOverride]? = nil) {
            self.enabled = enabled; self.reserveTokens = reserveTokens; self.keepRecentTokens = keepRecentTokens; self.modelOverrides = modelOverrides
        }
    }

    public struct BranchSummarySettings: Sendable, Hashable, Codable {
        public var reserveTokens: Int? // default: 16384 (tokens reserved for prompt + LLM response)
        public var skipPrompt: Bool? // default: false - when true, skips "Summarize branch?" prompt and defaults to no summary
        public init(reserveTokens: Int? = nil, skipPrompt: Bool? = nil) {
            self.reserveTokens = reserveTokens; self.skipPrompt = skipPrompt
        }
    }

    public struct ProviderRetrySettings: Sendable, Hashable, Codable {
        public var timeoutMs: Int?
        public var maxRetries: Int?
        public var maxRetryDelayMs: Int? // default: 60000
        public init(timeoutMs: Int? = nil, maxRetries: Int? = nil, maxRetryDelayMs: Int? = nil) {
            self.timeoutMs = timeoutMs; self.maxRetries = maxRetries; self.maxRetryDelayMs = maxRetryDelayMs
        }
    }

    public struct RetrySettings: Sendable, Hashable, Codable {
        public var enabled: Bool? // default: true
        public var maxRetries: Int? // default: 3
        public var baseDelayMs: Int? // default: 2000 (exponential backoff: 2s, 4s, 8s)
        public var maxAgentDelayMs: Int? // default: 60000
        public var provider: ProviderRetrySettings?
        public init(enabled: Bool? = nil, maxRetries: Int? = nil, baseDelayMs: Int? = nil, maxAgentDelayMs: Int? = nil, provider: ProviderRetrySettings? = nil) {
            self.enabled = enabled; self.maxRetries = maxRetries; self.baseDelayMs = baseDelayMs
            self.maxAgentDelayMs = maxAgentDelayMs; self.provider = provider
        }
    }

    public var compaction: CompactionSettings?
    public var branchSummary: BranchSummarySettings?
    public var retry: RetrySettings?
    public var skills: [String]?
    public var extensions: [String]?
    public var prompts: [String]?
    public var themes: [String]?
    public var enableSkillCommands: Bool?
    // Other setting groups round-trip through storage but have no typed accessors yet.

    public init(compaction: CompactionSettings? = nil, branchSummary: BranchSummarySettings? = nil, retry: RetrySettings? = nil) {
        self.compaction = compaction; self.branchSummary = branchSummary; self.retry = retry
    }
}

/// `SETTINGS_DEFAULTS` (subset).
public enum SETTINGS_DEFAULTS {
    public enum compaction {
        public static let enabled = true
        public static let reserveTokens = 16384
        public static let keepRecentTokens = 20000
    }
    public enum branchSummary {
        public static let reserveTokens = 16384
        public static let skipPrompt = false
    }
    public enum retry {
        public static let enabled = true
        public static let maxRetries = 3
        public static let baseDelayMs = 2000
        public static let maxAgentDelayMs = 60000
        public enum provider {
            public static let maxRetryDelayMs = 60000
        }
    }
}

// MARK: - settings-manager.ts

/// `Required<CompactionModelOverride>` token defaults.
private enum CompactionTokenField: String {
    case reserveTokens
    case keepRecentTokens

    var defaultValue: Int {
        switch self {
        case .reserveTokens: return SETTINGS_DEFAULTS.compaction.reserveTokens
        case .keepRecentTokens: return SETTINGS_DEFAULTS.compaction.keepRecentTokens
        }
    }

    func read(_ settings: Settings.CompactionSettings?) -> Double? {
        switch self {
        case .reserveTokens: return settings?.reserveTokens
        case .keepRecentTokens: return settings?.keepRecentTokens
        }
    }

    func read(_ override: Settings.CompactionModelOverride?) -> Double? {
        switch self {
        case .reserveTokens: return override?.reserveTokens
        case .keepRecentTokens: return override?.keepRecentTokens
        }
    }
}

/// `Number.isSafeInteger(value)`.
private func isSafeInteger(_ value: Double) -> Bool {
    value.isFinite && value.rounded(.towardZero) == value && abs(value) <= 9_007_199_254_740_991
}

/// `String(number)` for JS numbers.
private func jsNumberString(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
    if value.rounded(.towardZero) == value && abs(value) < 1e21 {
        return String(format: "%.0f", value)
    }
    return "\(value)"
}

/// `Pick<Model<string>, "provider" | "id">`
public struct SettingsModelRef: Sendable, Hashable {
    public var provider: String
    public var id: String
    public init(provider: String, id: String) { self.provider = provider; self.id = id }
    public init(_ model: Model) { self.provider = model.provider; self.id = model.id }
}

public final class SettingsManager: @unchecked Sendable {
    private let lock = NSLock()
    /// Swift: the effective settings (upstream merges global and project settings into `settings`).
    private var settings: Settings
    private var storage: (any SettingsStorage)?
    private var globalSettings = JsonObject()
    private var projectSettings = JsonObject()
    private var overrides = Settings()
    private var errors: [SettingsError] = []
    private var projectTrusted = true

    private init(_ settings: Settings) {
        self.settings = settings
        self.globalSettings = (try? JsonValue(encoding: settings).objectValue) ?? JsonObject()
    }

    /** Create an in-memory settings manager. */
    public static func inMemory(_ settings: Settings = Settings()) -> SettingsManager {
        SettingsManager(settings)
    }

    private func read<T>(_ body: (Settings) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(settings)
    }

    private func write(_ body: (inout Settings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let storage else { body(&settings); globalSettings = (try? JsonValue(encoding: settings).objectValue) ?? JsonObject(); return }
        let before = settings
        let previousGlobal = globalSettings
        do {
            var global = try JsonValue.object(globalSettings).decode(Settings.self)
            let old = try JsonValue(encoding: global).objectValue ?? JsonObject()
            body(&global)
            let new = try JsonValue(encoding: global).objectValue ?? JsonObject()
            try storage.withLock(.global) { current in
                var object = migrateSettingsObject(try parseSettingsObject(current))
                applySettingsChanges(before: old, after: new, to: &object)
                globalSettings = object
                return prettyConfigJSON(.object(object), indent: "  ") + "\n"
            }
            try recomputeSettings()
        } catch {
            settings = before
            globalSettings = previousGlobal
            errors.append(.init(scope: .global, message: errorMessage(error)))
        }
    }

    /** Apply additional overrides on top of current settings. */
    public func applyOverrides(_ overrides: Settings) {
        lock.lock(); defer { lock.unlock() }
        self.overrides = deepMergeSettings(self.overrides, overrides)
        settings = deepMergeSettings(settings, overrides)
    }

    public static func create(cwd: String, agentDir: String = getAgentDir(), projectTrusted: Bool = true) -> SettingsManager {
        fromStorage(FileSettingsStorage(cwd: cwd, agentDir: agentDir), projectTrusted: projectTrusted)
    }

    public static func fromStorage(_ storage: any SettingsStorage, projectTrusted: Bool = true) -> SettingsManager {
        let manager = SettingsManager(Settings())
        manager.storage = storage; manager.projectTrusted = projectTrusted
        manager.reload()
        return manager
    }

    public func reload() {
        lock.lock(); defer { lock.unlock() }
        guard let storage else { return }
        for scope in [SettingsScope.global, .project] {
            if scope == .project && !projectTrusted { projectSettings = JsonObject(); continue }
            do {
                try storage.withLock(scope) { current in
                    let object = migrateSettingsObject(try parseSettingsObject(current))
                    _ = try JsonValue.object(object).decode(Settings.self)
                    if scope == .global { globalSettings = object } else { projectSettings = object }
                    return nil
                }
            } catch { errors.append(.init(scope: scope, message: errorMessage(error))) }
        }
        do { try recomputeSettings() } catch { errors.append(.init(scope: .global, message: errorMessage(error))) }
    }

    private func recomputeSettings() throws {
        let combined = mergeSettingsObjects(globalSettings, projectSettings)
        settings = deepMergeSettings(try JsonValue.object(combined).decode(Settings.self), overrides)
    }
    public func drainErrors() -> [SettingsError] {
        lock.lock(); defer { lock.unlock() }
        let result = errors; errors.removeAll(); return result
    }
    public func getGlobalSettings() -> JsonObject {
        lock.lock(); defer { lock.unlock() }
        return storage == nil ? ((try? JsonValue(encoding: settings).objectValue) ?? JsonObject()) : globalSettings
    }
    public func getProjectSettings() -> JsonObject { lock.lock(); defer { lock.unlock() }; return projectSettings }
    public func isProjectTrusted() -> Bool { lock.lock(); defer { lock.unlock() }; return projectTrusted }
    public func getSkillPaths() -> [String] { read { $0.skills ?? [] } }
    public func setSkillPaths(_ paths: [String]) { write { $0.skills = paths } }
    public func getExtensionPaths() -> [String] { read { $0.extensions ?? [] } }
    public func setExtensionPaths(_ paths: [String]) { write { $0.extensions = paths } }
    public func getPromptTemplatePaths() -> [String] { read { $0.prompts ?? [] } }
    public func setPromptTemplatePaths(_ paths: [String]) { write { $0.prompts = paths } }
    public func getThemePaths() -> [String] { read { $0.themes ?? [] } }
    public func setThemePaths(_ paths: [String]) { write { $0.themes = paths } }
    public func getEnableSkillCommands() -> Bool { read { $0.enableSkillCommands ?? true } }
    public func setEnableSkillCommands(_ enabled: Bool) { write { $0.enableSkillCommands = enabled } }
    public func setProjectSkillPaths(_ paths: [String]) throws { try updateProjectSettings("skills", .array(paths.map(JsonValue.string))) }
    public func setProjectExtensionPaths(_ paths: [String]) throws { try updateProjectSettings("extensions", .array(paths.map(JsonValue.string))) }
    private func updateProjectSettings(_ key: String, _ value: JsonValue) throws {
        lock.lock(); defer { lock.unlock() }
        guard projectTrusted else { throw PiError("Project is not trusted") }
        if let storage {
            try storage.withLock(.project) { current in
                var object = migrateSettingsObject(try parseSettingsObject(current)); object[key] = value; projectSettings = object
                return prettyConfigJSON(.object(object), indent: "  ") + "\n"
            }
        } else { projectSettings[key] = value }
        try recomputeSettings()
    }

    public func getCompactionEnabled() -> Bool {
        read { $0.compaction?.enabled ?? SETTINGS_DEFAULTS.compaction.enabled }
    }

    /// Swift: updates the effective settings directly (upstream writes global settings and saves).
    public func setCompactionEnabled(_ enabled: Bool) {
        write { settings in
            if settings.compaction == nil {
                settings.compaction = Settings.CompactionSettings()
            }
            settings.compaction!.enabled = enabled
        }
    }

    private func getCompactionTokenSetting(_ field: CompactionTokenField, _ model: SettingsModelRef?) throws -> Int {
        let compaction = read { $0.compaction }
        let ordinary = field.read(compaction)
        if let ordinary, !isSafeInteger(ordinary) || ordinary < 0 {
            throw PiError(
                "Invalid compaction.\(field.rawValue) setting: \(jsNumberString(ordinary)). Expected a non-negative safe integer."
            )
        }

        let modelKey = model.map { "\($0.provider)/\($0.id)" }
        let entry = modelKey.flatMap { compaction?.modelOverrides?[$0] }
        // Not ported: the "Expected an object." check; entries are typed here.
        let override = field.read(entry)
        if let override, !isSafeInteger(override) || override < 0 {
            throw PiError(
                "Invalid compaction.modelOverrides[\"\(modelKey ?? "")\"].\(field.rawValue) setting: \(jsNumberString(override)). Expected a non-negative safe integer."
            )
        }
        return (override ?? ordinary).map { Int($0) } ?? field.defaultValue
    }

    public func getCompactionReserveTokens(_ model: SettingsModelRef? = nil) throws -> Int {
        try getCompactionTokenSetting(.reserveTokens, model)
    }

    public func getCompactionKeepRecentTokens(_ model: SettingsModelRef? = nil) throws -> Int {
        try getCompactionTokenSetting(.keepRecentTokens, model)
    }

    /** Resolve each token setting through model override, ordinary setting, then built-in default. */
    public func getCompactionSettings(_ model: SettingsModelRef? = nil) throws -> CompactionSettings {
        CompactionSettings(
            enabled: getCompactionEnabled(),
            reserveTokens: try getCompactionReserveTokens(model),
            keepRecentTokens: try getCompactionKeepRecentTokens(model)
        )
    }

    public func getCompactionSettings(_ model: Model?) throws -> CompactionSettings {
        try getCompactionSettings(model.map(SettingsModelRef.init))
    }

    public func getBranchSummarySettings() -> (reserveTokens: Int, skipPrompt: Bool) {
        read {
            (
                reserveTokens: $0.branchSummary?.reserveTokens ?? SETTINGS_DEFAULTS.branchSummary.reserveTokens,
                skipPrompt: $0.branchSummary?.skipPrompt ?? SETTINGS_DEFAULTS.branchSummary.skipPrompt
            )
        }
    }

    public func getBranchSummarySkipPrompt() -> Bool {
        read { $0.branchSummary?.skipPrompt ?? SETTINGS_DEFAULTS.branchSummary.skipPrompt }
    }

    public func getRetryEnabled() -> Bool {
        read { $0.retry?.enabled ?? SETTINGS_DEFAULTS.retry.enabled }
    }

    /// Swift: updates the effective settings directly (upstream writes global settings and saves).
    public func setRetryEnabled(_ enabled: Bool) {
        write { settings in
            if settings.retry == nil {
                settings.retry = Settings.RetrySettings()
            }
            settings.retry!.enabled = enabled
        }
    }

    /// `{ enabled, maxRetries, baseDelayMs, maxAgentDelayMs }` as a `RetryPolicy`.
    public func getRetrySettings() -> RetryPolicy {
        let enabled = getRetryEnabled()
        return read {
            RetryPolicy(
                enabled: enabled,
                maxRetries: $0.retry?.maxRetries ?? SETTINGS_DEFAULTS.retry.maxRetries,
                baseDelayMs: $0.retry?.baseDelayMs ?? SETTINGS_DEFAULTS.retry.baseDelayMs,
                maxAgentDelayMs: $0.retry?.maxAgentDelayMs ?? SETTINGS_DEFAULTS.retry.maxAgentDelayMs
            )
        }
    }

    public func getProviderRetrySettings() -> (timeoutMs: Int?, maxRetries: Int?, maxRetryDelayMs: Int) {
        read {
            (
                timeoutMs: $0.retry?.provider?.timeoutMs,
                maxRetries: $0.retry?.provider?.maxRetries,
                maxRetryDelayMs: $0.retry?.provider?.maxRetryDelayMs ?? SETTINGS_DEFAULTS.retry.provider.maxRetryDelayMs
            )
        }
    }
}

// MARK: - deepMergeSettings (subset)

/// `deepMergeSettings(base, overrides)`: nested objects merge per key; `undefined` override values are skipped.
func deepMergeSettings(_ base: Settings, _ overrides: Settings) -> Settings {
    var result = base
    if let value = overrides.skills { result.skills = value }
    if let value = overrides.extensions { result.extensions = value }
    if let value = overrides.prompts { result.prompts = value }
    if let value = overrides.themes { result.themes = value }
    if let value = overrides.enableSkillCommands { result.enableSkillCommands = value }
    if let o = overrides.compaction {
        var c = result.compaction ?? Settings.CompactionSettings()
        if let v = o.enabled { c.enabled = v }
        if let v = o.reserveTokens { c.reserveTokens = v }
        if let v = o.keepRecentTokens { c.keepRecentTokens = v }
        if let overrideMap = o.modelOverrides {
            var merged = c.modelOverrides ?? [:]
            for (key, value) in overrideMap {
                var entry = merged[key] ?? Settings.CompactionModelOverride()
                if let v = value.enabled { entry.enabled = v }
                if let v = value.reserveTokens { entry.reserveTokens = v }
                if let v = value.keepRecentTokens { entry.keepRecentTokens = v }
                merged[key] = entry
            }
            c.modelOverrides = merged
        }
        result.compaction = c
    }
    if let o = overrides.branchSummary {
        var b = result.branchSummary ?? Settings.BranchSummarySettings()
        if let v = o.reserveTokens { b.reserveTokens = v }
        if let v = o.skipPrompt { b.skipPrompt = v }
        result.branchSummary = b
    }
    if let o = overrides.retry {
        var r = result.retry ?? Settings.RetrySettings()
        if let v = o.enabled { r.enabled = v }
        if let v = o.maxRetries { r.maxRetries = v }
        if let v = o.baseDelayMs { r.baseDelayMs = v }
        if let v = o.maxAgentDelayMs { r.maxAgentDelayMs = v }
        if let p = o.provider {
            var rp = r.provider ?? Settings.ProviderRetrySettings()
            if let v = p.timeoutMs { rp.timeoutMs = v }
            if let v = p.maxRetries { rp.maxRetries = v }
            if let v = p.maxRetryDelayMs { rp.maxRetryDelayMs = v }
            r.provider = rp
        }
        result.retry = r
    }
    return result
}
