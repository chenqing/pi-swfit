// Port surface: packages/mcp/src/transports/transport.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
import Foundation
import PiAI

public let DEFAULT_MAX_MESSAGE_BYTES = 16 * 1024 * 1024
public struct McpTransportEvents: Sendable {
    public var onMessage: @Sendable (JsonObject) async -> Void
    public var onError: @Sendable (any Error) async -> Void
    public var onClose: @Sendable () async -> Void
    public init(onMessage: @escaping @Sendable (JsonObject) async -> Void,
                onError: @escaping @Sendable (any Error) async -> Void,
                onClose: @escaping @Sendable () async -> Void) {
        self.onMessage = onMessage; self.onError = onError; self.onClose = onClose
    }
}
/// Swift uses one event sink per transport; the client fans notifications out to subscribers.
public protocol McpTransport: Sendable {
    func start(events: McpTransportEvents) async throws
    func send(_ message: JsonObject, signal: AbortSignal?) async throws
    func close() async
    func setProtocolVersion(_ version: String) async
}
public extension McpTransport { func setProtocolVersion(_ version: String) async {} }
