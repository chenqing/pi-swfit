import Foundation
import Network

// Swift-only: a minimal one-request-per-connection HTTP/1.1 server on a loopback address, the stand-in for
// `node:http` `createServer` / `listen` / `close` / `closeAllConnections` used by the OAuth callback servers.
// Built on Network.framework `NWListener`. Every response carries `Connection: close`.

/// A received request: method and request target (`request.url`, path plus query).
struct LoopbackHTTPRequest: Sendable {
    var method: String
    var url: String
}

struct LoopbackHTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: String
}

/// `listen` failure, shaped like Node's system errors (`code: "EADDRINUSE"`, ...).
public struct LoopbackListenError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public var message: String
    public var code: String?
    public init(_ message: String, code: String? = nil) { self.message = message; self.code = code }
    public var description: String { message }
    public var errorDescription: String? { message }
}

final class LoopbackHTTPServer: Sendable {
    typealias Handler = @Sendable (LoopbackHTTPRequest) async -> LoopbackHTTPResponse

    private struct State {
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var closed = false
        var onError: (@Sendable (any Error) -> Void)?
        var port = 0
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: Handler
    private let state = Locked(State())
    private let stopped = PendingResult<Void>()
    /// The bound port (`server.address().port`).
    var port: Int { state.withLock { $0.port } }

    private init(listener: NWListener, queue: DispatchQueue, handler: @escaping Handler) {
        self.listener = listener; self.queue = queue; self.handler = handler
    }

    /// `server.listen(port, host)`; `port` 0 picks a free port. Rejects with `LoopbackListenError` on bind failure.
    static func listen(host: String, port: Int, handler: @escaping Handler) async throws -> LoopbackHTTPServer {
        guard (0...65535).contains(port) else {
            throw LoopbackListenError("options.port should be >= 0 and < 65536. Received \(port).", code: "ERR_SOCKET_BAD_PORT")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true  // libuv sets SO_REUSEADDR on listening sockets
        parameters.acceptLocalOnly = false
        let nwPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(port))!
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw mapListenError(error, host: host, port: port)
        }
        let queue = DispatchQueue(label: "pi.oauth.loopback-http")
        let server = LoopbackHTTPServer(listener: listener, queue: queue, handler: handler)
        let ready = PendingResult<Int>()
        let stopped = server.stopped

        listener.newConnectionHandler = { [weak server] connection in
            guard let server else {
                connection.cancel()
                return
            }
            server.accept(connection)
        }
        listener.stateUpdateHandler = { [weak server, weak listener] state in
            switch state {
            case .ready:
                ready.resolve(Int(listener?.port?.rawValue ?? 0))
            case .cancelled:
                stopped.resolve(())
            case .failed(let error), .waiting(let error):
                if ready.isSettled {
                    server?.reportError(mapListenError(error, host: host, port: port))
                } else {
                    ready.reject(mapListenError(error, host: host, port: port))
                    listener?.cancel()
                }
            default:
                break
            }
        }
        listener.start(queue: queue)
        do {
            let boundPort = try await ready.value()
            server.state.withLock { $0.port = boundPort }
        } catch {
            listener.cancel()
            throw error
        }
        return server
    }

    private static func mapListenError(_ error: any Error, host: String, port: Int) -> LoopbackListenError {
        if case NWError.posix(let code) = error {
            switch code {
            case .EADDRINUSE: return LoopbackListenError("listen EADDRINUSE: address already in use \(host):\(port)", code: "EADDRINUSE")
            case .EADDRNOTAVAIL: return LoopbackListenError("listen EADDRNOTAVAIL: address not available \(host):\(port)", code: "EADDRNOTAVAIL")
            case .EACCES: return LoopbackListenError("listen EACCES: permission denied \(host):\(port)", code: "EACCES")
            default: return LoopbackListenError("listen \(code): \(error.localizedDescription) \(host):\(port)", code: "\(code)")
            }
        }
        return LoopbackListenError("listen failed: \(error.localizedDescription) \(host):\(port)")
    }

    /// `server.on("error", fn)` after listening.
    func onError(_ fn: @escaping @Sendable (any Error) -> Void) {
        state.withLock { $0.onError = fn }
    }

    private func reportError(_ error: any Error) {
        let fn = state.withLock { $0.onError }
        fn?(error)
    }

    /// `server.close()`: stop accepting connections. In-flight requests still get their response.
    func close() {
        let alreadyClosed = state.withLock { s -> Bool in
            defer { s.closed = true }
            return s.closed
        }
        if !alreadyClosed { listener.cancel() }
    }

    /// Network.framework releases the listening socket asynchronously. Wait for cancellation
    /// before starting another login on the same fixed callback port.
    func closeAndWait() async {
        close()
        _ = try? await stopped.value()
    }

    /// `server.closeAllConnections()`.
    func closeAllConnections() {
        let connections = state.withLock { s -> [NWConnection] in
            defer { s.connections = [:] }
            return Array(s.connections.values)
        }
        connections.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let closed = state.withLock { s -> Bool in
            if !s.closed { s.connections[id] = connection }
            return s.closed
        }
        if closed {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let content { buffer.append(content) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.handle(connection, head: head)
                return
            }
            if error != nil || isComplete || buffer.count > 1_048_576 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func handle(_ connection: NWConnection, head: String) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else {
            send(connection, LoopbackHTTPResponse(status: 400, headers: [], body: ""))
            return
        }
        let request = LoopbackHTTPRequest(method: parts[0], url: parts[1])
        let handler = self.handler
        Task {
            let response = await handler(request)
            self.send(connection, response)
        }
    }

    private func send(_ connection: NWConnection, _ response: LoopbackHTTPResponse) {
        let body = Data(response.body.utf8)
        var head = "HTTP/1.1 \(response.status) \(Self.reasonPhrase(response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
    }
}
