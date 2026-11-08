import Foundation
import Network
import Testing
@testable import PiAI

struct ResponseBodyCancellationTests {
    @Test func explicitCancellationClosesAnUnfinishedNetworkResponse() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let connection = Locked<NWConnection?>(nil)
        let ready = Locked(false), disconnected = Locked(false)
        let queue = DispatchQueue(label: "pi-test-body-cancellation")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.withLock { $0 = true } } }
        listener.newConnectionHandler = { client in
            connection.withLock { $0 = client }
            client.start(queue: queue)
            client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                let bytes = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 99999\r\n\r\ndata: first\n\n".utf8)
                client.send(content: bytes, completion: .contentProcessed { _ in
                    // The server never finishes this response. Only the caller can end it.
                    client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, done, error in
                        if done || error != nil { disconnected.withLock { $0 = true } }
                    }
                })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel(); connection.current?.cancel() }
        for _ in 0..<200 where !ready.current { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ready.current)
        let port = try #require(listener.port)
        let response = try await defaultFetch(.init(url: URL(string: "http://127.0.0.1:\(port.rawValue)/stream")!, timeoutMs: 2000))
        var iterator = response.body.makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == false)
        response.body.cancel()
        response.body.cancel()
        for _ in 0..<200 where !disconnected.current { try await Task.sleep(for: .milliseconds(5)) }
        #expect(disconnected.current)
        await #expect(throws: (any Error).self) { _ = try await iterator.next() }
    }
}
