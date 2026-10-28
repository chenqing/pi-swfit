// Native resolver for core/resolve-config-value.ts. Parsing never invokes this executor.
import Foundation
import PiAI
#if os(macOS)
import Darwin
#endif

public actor McpConfigValueResolver {
    private var cached: [String: (Date, String)] = [:]
    public init() {}
    public func resolve(_ value: String, cwd: String, signal: AbortSignal?) async throws -> String {
        try signal?.throwIfAborted()
        guard value.hasPrefix("!") else { return try resolveMcpConfigValue(value) }
        let key = cwd + "\0" + value
        if let (date, output) = cached[key], Date().timeIntervalSince(date) < 60 { return output }
        #if os(macOS)
        let command = String(value.dropFirst())
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PiError("Empty MCP configuration command") }
        let output = try await runConfigCommand(command, cwd: cwd, signal: signal)
        cached[key] = (Date(), output)
        return output
        #else
        throw PiError("Command-backed configuration is unavailable on this platform")
        #endif
    }
    public func clear() { cached.removeAll() }
}
#if os(macOS)
private func runConfigCommand(_ command: String, cwd: String, signal: AbortSignal?) async throws -> String {
    let cancellation = AbortController()
    let combined = combineAbortSignals([signal, cancellation.signal, AbortSignal.timeout(10_000)])
    defer { combined.cleanup() }
    return try await withTaskCancellationHandler {
        try combined.signal?.throwIfAborted()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let output = Pipe()
                let handles = [output.fileHandleForReading, output.fileHandleForWriting]
                defer { handles.forEach { try? $0.close() } }
                var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
                guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
                    continuation.resume(throwing: PiError("Cannot initialize configuration command")); return
                }
                defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
                for handle in handles { _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) }
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
                posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
                posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
                for handle in handles { posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor) }
                posix_spawn_file_actions_addchdir_np(&actions, cwd)
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)); posix_spawnattr_setpgroup(&attributes, 0)
                let arguments = ["/bin/sh", "-c", command].map { strdup($0) }
                let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
                defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
                var argv = arguments + [nil], envp = environment + [nil], child: pid_t = 0
                let result = posix_spawn(&child, "/bin/sh", &actions, &attributes, &argv, &envp)
                guard result == 0 else { continuation.resume(throwing: PiError("Cannot start configuration command")); return }
                let pid = child
                let listener = combined.signal?.addEventListener { _ = kill(-pid, SIGKILL) }
                defer { if let listener { combined.signal?.removeEventListener(listener) }; _ = kill(-pid, SIGKILL) }
                if combined.signal?.aborted == true { _ = kill(-pid, SIGKILL) }
                try? output.fileHandleForWriting.close()
                var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096), failed = false
                while true {
                    let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 { if errno == EINTR { continue }; failed = true; break }
                    bytes.append(contentsOf: buffer.prefix(count))
                    if bytes.count > 64 * 1024 { failed = true; _ = kill(-pid, SIGKILL); break }
                }
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                do {
                    try combined.signal?.throwIfAborted()
                    guard status == 0, !failed, let text = String(data: bytes, encoding: .utf8) else { throw PiError("MCP configuration command failed or exceeded its output limit") }
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { throw PiError("MCP configuration command returned an empty value") }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    } onCancel: { cancellation.abort() }
}
#endif
