import Foundation
import PiAI
import PiAgent
#if os(macOS)
import Darwin
#endif

/// Native subset of pi-coding-agent tools. Input schemas follow upstream; see Docs/CLI.md for limits.
public func createCodingTools(cwd: String) -> [AgentTool] {
    func schema(_ properties: JsonObject, _ required: [String]) -> JsonValue {
        .object(["type": "object", "properties": .object(properties), "required": .array(required.map(JsonValue.string))])
    }
    let string: JsonValue = ["type": "string"]
    @Sendable func path(_ args: JsonValue) throws -> URL {
        guard let raw = args["path"]?.stringValue, !raw.isEmpty else { throw PiError("path must not be empty") }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)).standardizedFileURL
    }
    @Sendable func result(_ text: String) -> AgentToolResult { .init(content: [.text(TextContent(text: text))]) }
    @Sendable func readText(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 10 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 10 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw PiError("Expected a UTF-8 text file no larger than 10 MiB")
        }
        return text
    }
    let read = AgentTool(name: "read", label: "Read", description: "Read a UTF-8 text file. offset is 1-based. Output is limited to 2000 lines or 50 KiB. Use offset/limit to page.",
                         parameters: schema(["path": string, "offset": ["type": "integer", "minimum": 1], "limit": ["type": "integer", "minimum": 1]], ["path"])) { _, args, signal, _ in
        try signal?.throwIfAborted()
        let text = try readText(path(args))
        let lines = text.components(separatedBy: "\n")
        let offsetValue = args["offset"]?.doubleValue ?? 1
        let limitValue = args["limit"]?.doubleValue ?? 2000
        guard offsetValue.isFinite, limitValue.isFinite, offsetValue >= 1, limitValue >= 1,
              offsetValue.rounded() == offsetValue, limitValue.rounded() == limitValue,
              offsetValue < Double(Int.max), limitValue < Double(Int.max) else { throw PiError("offset and limit must be positive integers") }
        let start = Int(offsetValue) - 1
        guard start < lines.count else { throw PiError("Offset is beyond the end of the file (\(lines.count) lines)") }
        var selected: [String] = []; var bytes = 0
        for line in lines.dropFirst(start).prefix(min(2000, Int(limitValue))) {
            if bytes + line.utf8.count + 1 > 50 * 1024 { break }
            selected.append(line); bytes += line.utf8.count + 1
        }
        guard !selected.isEmpty else { throw PiError("The selected line exceeds the 50 KiB output limit") }
        let next = start + selected.count
        return result(selected.joined(separator: "\n") + (next < lines.count ? "\n\n[Showing lines \(start + 1)-\(next) of \(lines.count). Use offset=\(next + 1) to continue.]" : ""))
    }
    let write = AgentTool(name: "write", label: "Write", description: "Write UTF-8 text to a file, creating parent directories and replacing existing contents.",
                          parameters: schema(["path": string, "content": string], ["path", "content"])) { _, args, signal, _ in
        try signal?.throwIfAborted()
        let url = try path(args)
        let content = args["content"]?.stringValue ?? ""
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return result("Successfully wrote \(content.utf8.count) bytes to \(url.path)")
    }
    let edit = AgentTool(name: "edit", label: "Edit", description: "Apply disjoint exact replacements. Each oldText must occur exactly once in the original file. All edits are validated before writing.",
                         parameters: schema(["path": string, "edits": ["type": "array", "minItems": 1, "items": schema(["oldText": string, "newText": string], ["oldText", "newText"])]], ["path", "edits"])) { _, args, signal, _ in
        try signal?.throwIfAborted()
        let url = try path(args)
        let original = try readText(url)
        guard let edits = args["edits"]?.arrayValue, !edits.isEmpty else { throw PiError("edits must not be empty") }
        var replacements: [(Range<String.Index>, String)] = []
        for edit in edits {
            guard let old = edit["oldText"]?.stringValue, !old.isEmpty, let new = edit["newText"]?.stringValue,
                  let range = original.range(of: old), original.range(of: old, range: original.index(after: range.lowerBound)..<original.endIndex) == nil else {
                throw PiError("oldText must occur exactly once in the original file")
            }
            guard !replacements.contains(where: { $0.0.overlaps(range) }) else { throw PiError("Edits must not overlap") }
            replacements.append((range, new))
        }
        var changed = original
        for (range, new) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { changed.replaceSubrange(range, with: new) }
        try signal?.throwIfAborted()
        guard try readText(url) == original else { throw PiError("File changed while preparing edits") }
        try changed.write(to: url, atomically: true, encoding: .utf8)
        return result("Successfully applied \(replacements.count) edits to \(url.path)")
    }
    let bash = AgentTool(name: "bash", label: "Bash", description: "Execute a bash command in the current directory. Returns combined stdout/stderr, capped to the last 2000 lines or 50 KiB. timeout is optional, in seconds.",
                         parameters: schema(["command": string, "timeout": ["type": "number", "exclusiveMinimum": 0]], ["command"])) { _, args, signal, _ in
        #if os(macOS)
        return try await runShell(command: args["command"]?.stringValue ?? "", cwd: cwd, timeout: args["timeout"]?.doubleValue, signal: signal)
        #else
        throw PiError("The native bash tool currently requires macOS")
        #endif
    }
    return [read, bash, edit, write]
}

#if os(macOS)
private func runShell(command: String, cwd: String, timeout: Double?, signal: AbortSignal?) async throws -> AgentToolResult {
    try signal?.throwIfAborted()
    if let timeout, !timeout.isFinite || timeout <= 0 || timeout > 2_147_483.647 { throw PiError("Invalid timeout") }
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("pf-output-\(UUID().uuidString).txt")
    let fd = open(outputURL.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
    guard fd >= 0 else { throw PiError("Cannot create shell output file") }
    defer { close(fd) }
    var keepOutput = false
    defer { if !keepOutput { try? FileManager.default.removeItem(at: outputURL) } }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    posix_spawn_file_actions_addchdir_np(&actions, cwd)
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, fd)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)
    let commandArguments: [String] = ["/bin/bash", "-c", command]
    let argv = commandArguments.map { argument in argument.withCString { strdup($0) } } + [nil]
    let env = ProcessInfo.processInfo.environment.map { key, value in
        (key + "=" + value).withCString { strdup($0) }
    } + [nil]
    defer { argv.forEach { free($0) }; env.forEach { free($0) } }
    var pid: pid_t = 0
    let start = Date()
    let code = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
        posix_spawn(&pid, "/bin/bash", &actions, &attributes, a.baseAddress!, e.baseAddress!)
    } }
    guard code == 0 else { throw PiError("Unable to launch bash: \(String(cString: strerror(code)))") }
    var status: Int32 = 0
    while true {
        let waited = waitpid(pid, &status, WNOHANG)
        if waited == pid { break }
        if waited < 0 {
            if errno == EINTR { continue }
            throw PiError("Unable to wait for bash: \(String(cString: strerror(errno)))")
        }
        if signal?.aborted == true || Task.isCancelled || (timeout.map { Date().timeIntervalSince(start) >= $0 } ?? false) {
            kill(-pid, SIGTERM)
            try? await Task.sleep(for: .milliseconds(100))
            kill(-pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            if signal?.aborted == true { try signal?.throwIfAborted() }
            if Task.isCancelled { throw CancellationError() }
            throw PiError("Command timed out")
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    let handle = try FileHandle(forReadingFrom: outputURL); defer { try? handle.close() }
    let size = try handle.seekToEnd()
    try handle.seek(toOffset: size > 50 * 1024 ? size - 50 * 1024 : 0)
    let data = try handle.read(upToCount: 50 * 1024) ?? Data()
    let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    let truncated = size > 50 * 1024 || lines.count > 2000
    keepOutput = truncated
    let output = lines.suffix(2000).joined(separator: "\n")
    let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    let display = output + (truncated ? "\n[Output truncated. Full output: \(outputURL.path)]" : "")
    var structured: JsonObject = ["output": .string(output), "truncated": .bool(truncated), "exit_code": .int(Int(exitCode)), "wall_time_seconds": .number(Date().timeIntervalSince(start))]
    if truncated { structured["full_output_path"] = .string(outputURL.path) }
    return AgentToolResult(content: [.text(TextContent(text: display))], structuredContent: .object(structured), isError: exitCode != 0)
}
#endif
