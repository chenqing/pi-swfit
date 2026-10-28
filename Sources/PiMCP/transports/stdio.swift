// Port: packages/mcp/src/transports/stdio.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
// Swift platform implementation: posix_spawn creates a process group before exec, avoiding
// the race in setting a Foundation.Process group after the child has already started.
#if os(macOS)
import Foundation
import Darwin
import PiAI

private let liveProcessGroups = Locked<Set<Int32>>([])
private let installExitHook: Void = {
    atexit { for pid in liveProcessGroups.withLock({ $0 }) { _ = kill(-pid, SIGTERM) } }
}()

public struct StdioTransportOptions: Sendable {
    public var command: String
    public var args: [String]
    public var cwd: String?
    public var env: [String: String]
    public var inheritEnv: Bool
    public var maxMessageBytes: Int
    public var maxStderrBytes: Int
    public var closeTimeoutMs: Int
    public init(command: String, args: [String] = [], cwd: String? = nil, env: [String: String] = [:],
                inheritEnv: Bool = true, maxMessageBytes: Int = DEFAULT_MAX_MESSAGE_BYTES,
                maxStderrBytes: Int = 64 * 1024, closeTimeoutMs: Int = 2_000) {
        self.command = command; self.args = args; self.cwd = cwd; self.env = env; self.inheritEnv = inheritEnv
        self.maxMessageBytes = maxMessageBytes; self.maxStderrBytes = maxStderrBytes; self.closeTimeoutMs = closeTimeoutMs
    }
}
public actor StdioTransport: McpTransport {
    public let options: StdioTransportOptions
    public private(set) var pid: Int32?
    public var stderr: String { String(decoding: stderrBuffer, as: UTF8.self) }
    private var stderrBuffer = Data()
    private var events: McpTransportEvents?
    private var input: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var closed = false
    private var started = false
    private let writeQueue = DispatchQueue(label: "pi.mcp.stdin")
    public init(options: StdioTransportOptions) { self.options = options }
    deinit {
        try? input?.close()
        if let child = pid {
            // Deinitialization cannot await the normal graceful close sequence.
            _ = kill(-child, SIGKILL)
            _ = liveProcessGroups.withLock { $0.remove(child) }
        }
    }

    public func start(events: McpTransportEvents) async throws {
        guard !closed else { throw McpConnectionClosedError() }
        guard !started else { throw PiError("MCP stdio transport already started") }
        started = true; self.events = events
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw PiError("Cannot initialize MCP process") }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let pipes = [stdin.fileHandleForReading, stdin.fileHandleForWriting, stdout.fileHandleForReading,
                     stdout.fileHandleForWriting, stderr.fileHandleForReading, stderr.fileHandleForWriting]
        for handle in pipes { _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) }
        posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        for handle in pipes { posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor) }
        if let cwd = options.cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var environment = options.inheritEnv ? ProcessInfo.processInfo.environment : [:]
        environment.merge(options.env) { _, new in new }
        // Resolve against the child's PATH (posix_spawnp would use the host's PATH).
        let executable: String
        if options.command.contains("/") { executable = options.command }
        else {
            executable = (environment["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":")
                .map { ($0.isEmpty ? (options.cwd ?? FileManager.default.currentDirectoryPath) : $0) + "/" + options.command }
                .first { access($0, X_OK) == 0 } ?? options.command
        }
        let arguments = ([options.command] + options.args).map { argument in argument.withCString { strdup($0) } }
        let env = environment.map { key, value in (key + "=" + value).withCString { strdup($0) } }
        defer { arguments.forEach { free($0) }; env.forEach { free($0) } }
        var argv = arguments + [nil], envp = env + [nil], child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, &argv, &envp)
        guard status == 0 else { throw PiError("Cannot start MCP server: \(String(cString: strerror(status)))") }
        pid = child; input = stdin.fileHandleForWriting
        _ = installExitHook
        _ = liveProcessGroups.withLock { $0.insert(child) }
        _ = fcntl(input!.fileDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        let outputStream = Self.chunks(stdout.fileHandleForReading)
        let errorStream = Self.chunks(stderr.fileHandleForReading)
        outputTask = Task { [weak self] in
            var buffer = Data()
            do {
                for try await chunk in outputStream {
                    buffer.append(chunk)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                        guard line.count <= self?.options.maxMessageBytes ?? 0 else { throw PiError("MCP message exceeds size limit") }
                        if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
                        let message = try parseJsonRpcMessage(JsonValue.parse(String(decoding: line, as: UTF8.self)))
                        await self?.emitMessage(message)
                    }
                    guard buffer.count <= self?.options.maxMessageBytes ?? 0 else { throw PiError("MCP message exceeds size limit") }
                }
                if !buffer.isEmpty { throw PiError("MCP stdio server closed with an incomplete JSON-RPC message") }
            } catch { await self?.emitError(error); await self?.close() }
        }
        errorTask = Task { [weak self] in
            do { for try await chunk in errorStream { await self?.recordStderr(chunk) } }
            catch { await self?.emitError(error) }
        }
        let processID = child
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
            Task { await self?.exited() }
        }
    }
    private static func chunks(_ handle: FileHandle) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
            DispatchQueue.global().async {
                defer { try? handle.close() }
                do {
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        // FileHandle.read(upToCount:) may wait to fill the requested size on a
                        // pipe. POSIX read returns immediately with each available protocol frame.
                        let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                        if count == 0 { break }
                        if count < 0 { if errno == EINTR { continue }; throw PiError("Cannot read MCP process output") }
                        let chunk = Data(buffer.prefix(count))
                        if case .dropped = continuation.yield(chunk) { throw PiError("MCP output exceeded consumer buffer limit") }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
    private func emitMessage(_ message: JsonObject) async { if !closed { await events?.onMessage(message) } }
    private func emitError(_ error: any Error) async { if !closed { await events?.onError(error) } }
    private func recordStderr(_ data: Data) { stderrBuffer.append(data); if stderrBuffer.count > options.maxStderrBytes { stderrBuffer = stderrBuffer.suffix(options.maxStderrBytes) } }
    private func exited() async {
        let child = pid
        if let child {
            _ = kill(-child, SIGTERM)
            // A wrapper may exit while a descendant still holds stdout open.
            let timeout = options.closeTimeoutMs
            Task {
                try? await Task.sleep(for: .milliseconds(timeout))
                _ = kill(-child, SIGKILL)
            }
        }
        await outputTask?.value
        pid = nil
        if let child { _ = liveProcessGroups.withLock { $0.remove(child) } }
        await close()
    }
    public func send(_ message: JsonObject, signal: AbortSignal?) async throws {
        try signal?.throwIfAborted()
        guard started, !closed, let input else { throw McpConnectionClosedError() }
        let payload = Data((JsonValue.object(message).serialized() + "\n").utf8)
        guard payload.count <= options.maxMessageBytes else { throw PiError("MCP message exceeds size limit") }
        let fd = dup(input.fileDescriptor)
        guard fd >= 0 else { throw McpConnectionClosedError() }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                defer { _ = Darwin.close(fd) }
                do {
                    try payload.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            try signal?.throwIfAborted()
                            let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if written > 0 { offset += written }
                            else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                                _ = poll(&descriptor, 1, 50)
                            } else { throw McpConnectionClosedError() }
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func close() async {
        guard !closed else { return }; closed = true
        try? input?.close(); input = nil
        if let child = pid {
            try? await Task.sleep(for: .milliseconds(min(500, options.closeTimeoutMs)))
            _ = kill(-child, SIGTERM)
            try? await Task.sleep(for: .milliseconds(options.closeTimeoutMs))
            _ = kill(-child, SIGKILL)
        }
        await events?.onClose()
    }
}
#endif
