import Foundation
import PiAI
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SettingsScope: String, Sendable { case global, project }
public struct SettingsError: Sendable { public var scope: SettingsScope; public var message: String }
public protocol SettingsStorage: Sendable {
    func withLock(_ scope: SettingsScope, _ body: (String?) throws -> String?) throws
}
public final class InMemorySettingsStorage: SettingsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SettingsScope: String]
    public init(global: String? = nil, project: String? = nil) {
        values = [:]; values[.global] = global; values[.project] = project
    }
    public func withLock(_ scope: SettingsScope, _ body: (String?) throws -> String?) throws {
        lock.lock(); defer { lock.unlock() }
        if let next = try body(values[scope]) { values[scope] = next }
    }
}
public final class FileSettingsStorage: SettingsStorage, Sendable {
    public let globalSettingsPath: String
    public let projectSettingsPath: String
    public init(cwd: String, agentDir: String) {
        globalSettingsPath = resolvePath(agentDir, FileManager.default.currentDirectoryPath) + "/settings.json"
        projectSettingsPath = resolvePath(cwd, FileManager.default.currentDirectoryPath) + "/.pi/settings.json"
    }
    public func withLock(_ scope: SettingsScope, _ body: (String?) throws -> String?) throws {
        let path = scope == .global ? globalSettingsPath : projectSettingsPath
        try withLockedJSONFile(path, body)
    }
}

/// Uses proper-lockfile's `<path>.lock` directory convention so Swift and upstream Pi coordinate.
/// The directory lease is refreshed while held; a crashed writer's stale lease can be reclaimed.
/// Atomic rename additionally prevents readers seeing partially written JSON.
func withLockedJSONFile(_ path: String, _ body: (String?) throws -> String?) throws {
    let fm = FileManager.default
    var prepared: String?
    if !fm.fileExists(atPath: path) {
        // Read-only access must not create configuration directories.
        prepared = try body(nil)
        guard prepared != nil else { return }
    }
    let url = URL(fileURLWithPath: path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lockPath = path + ".lock"
    var acquired = false
    for attempt in 0..<10 {
        if mkdir(lockPath, S_IRWXU) == 0 { acquired = true; break }
        guard errno == EEXIST else { throw PiError("Cannot lock settings file: \(path)") }
        if let attributes = try? fm.attributesOfItem(atPath: lockPath),
           attributes[.type] as? FileAttributeType == .typeDirectory,
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) > 10 {
            _ = rmdir(lockPath)
        }
        if attempt < 9 { Thread.sleep(forTimeInterval: 0.02) }
    }
    guard acquired else { throw PiError("Settings file is already locked: \(path)") }
    let descriptor = open(lockPath, O_RDONLY)
    guard descriptor >= 0 else { _ = rmdir(lockPath); throw PiError("Cannot open settings lock: \(path)") }
    func ownsLease() -> Bool {
        var held = stat(), current = stat()
        return fstat(descriptor, &held) == 0 && lstat(lockPath, &current) == 0
            && held.st_ino == current.st_ino && held.st_dev == current.st_dev
    }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now() + 5, repeating: 5)
    // An open descriptor refers to this lease even if the pathname is replaced after a crash.
    timer.setEventHandler { _ = futimes(descriptor, nil) }
    timer.setCancelHandler { _ = close(descriptor) }
    timer.resume()
    defer { if ownsLease() { _ = rmdir(lockPath) }; timer.cancel() }
    let current = fm.fileExists(atPath: path) ? try String(contentsOf: url, encoding: .utf8) : nil
    // Re-evaluate only if a competing writer created the file before we obtained the lock.
    let next = current == nil && prepared != nil ? prepared : try body(current)
    if let next {
        guard ownsLease() else { throw PiError("Settings lock was replaced: \(path)") }
        try Data(next.utf8).write(to: url, options: .atomic)
    }
}
func parseSettingsObject(_ text: String?) throws -> JsonObject {
    guard let text else { return JsonObject() }
    let clean = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
    guard let value = try JsonValue.parse(clean).objectValue else { throw PiError("Settings must be an object") }
    return value
}
func mergeSettingsObjects(_ base: JsonObject, _ override: JsonObject) -> JsonObject {
    var result = base
    for (key, value) in override {
        if let lhs = result[key]?.objectValue, let rhs = value.objectValue { result[key] = .object(mergeSettingsObjects(lhs, rhs)) }
        else { result[key] = value }
    }
    return result
}
func applySettingsChanges(before: JsonObject, after: JsonObject, to object: inout JsonObject) {
    for key in Set(before.keys + after.keys) where before[key] != after[key] {
        if let lhs = before[key]?.objectValue, let rhs = after[key]?.objectValue {
            var nested = object[key]?.objectValue ?? JsonObject()
            applySettingsChanges(before: lhs, after: rhs, to: &nested); object[key] = .object(nested)
        } else { object[key] = after[key] }
    }
}

/// Migrations from settings-manager.ts. Reads migrate the in-memory view; the file changes only
/// on an explicit setter. Unknown settings survive both migration and subsequent edits.
func migrateSettingsObject(_ source: JsonObject) -> JsonObject {
    var settings = source
    if let queue = settings["queueMode"], settings["steeringMode"] == nil { settings["steeringMode"] = queue; settings["queueMode"] = nil }
    if settings["transport"] == nil, let websockets = settings["websockets"]?.boolValue {
        settings["transport"] = .string(websockets ? "websocket" : "sse"); settings["websockets"] = nil
    }
    if let legacy = settings["skills"]?.objectValue {
        if settings["enableSkillCommands"] == nil { settings["enableSkillCommands"] = legacy["enableSkillCommands"] }
        if let paths = legacy["customDirectories"]?.arrayValue, !paths.isEmpty { settings["skills"] = .array(paths) }
        else { settings["skills"] = nil }
    }
    if var retry = settings["retry"]?.objectValue {
        var provider = retry["provider"]?.objectValue ?? JsonObject()
        if let delay = retry["maxDelayMs"]?.doubleValue, provider["maxRetryDelayMs"] == nil || provider["maxRetryDelayMs"] == .null {
            provider["maxRetryDelayMs"] = .number(delay); retry["provider"] = .object(provider)
        }
        retry["maxDelayMs"] = nil; settings["retry"] = .object(retry)
    }
    return settings
}

func prettyConfigJSON(_ value: JsonValue, indent: String, level: Int = 0) -> String {
    let padding = String(repeating: indent, count: level), childPadding = padding + indent
    switch value {
    case .object(let object):
        if object.isEmpty { return "{}" }
        return "{\n" + object.map { childPadding + JsonValue.string($0.0).serialized() + ": " + prettyConfigJSON($0.1, indent: indent, level: level + 1) }.joined(separator: ",\n") + "\n" + padding + "}"
    case .array(let values):
        if values.isEmpty { return "[]" }
        return "[\n" + values.map { childPadding + prettyConfigJSON($0, indent: indent, level: level + 1) }.joined(separator: ",\n") + "\n" + padding + "]"
    default: return value.serialized()
    }
}
