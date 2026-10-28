import PiAI

public struct McpError: Error, Sendable, CustomStringConvertible {
    public let code: Int
    public let message: String
    public let data: JsonValue?
    public init(_ code: Int, _ message: String, data: JsonValue? = nil) { self.code = code; self.message = message; self.data = data }
    public var description: String { message }
}
public struct McpConnectionClosedError: Error, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ message: String = "MCP connection closed") { description = message }
}
public struct McpTimeoutError: Error, Sendable, CustomStringConvertible {
    public var timeoutMs: Int
    public init(_ timeoutMs: Int) { self.timeoutMs = timeoutMs }
    public var description: String { "MCP request timed out after \(timeoutMs)ms" }
}
public struct McpAbortError: Error, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ message: String = "MCP request aborted") { description = message }
}
public let LATEST_PROTOCOL_VERSION = "2025-11-25"
public let SUPPORTED_PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

public func isJsonRpcId(_ value: JsonValue?) -> Bool {
    value?.stringValue != nil || value?.doubleValue?.isFinite == true
}
public func isJsonRpcRequest(_ message: JsonObject) -> Bool {
    message["jsonrpc"] == .string("2.0") && isJsonRpcId(message["id"]) && message["method"]?.stringValue != nil
}
public func isJsonRpcNotification(_ message: JsonObject) -> Bool {
    message["jsonrpc"] == .string("2.0") && message["id"] == nil && message["method"]?.stringValue != nil
}
public func isJsonRpcResponse(_ message: JsonObject) -> Bool {
    guard message["jsonrpc"] == .string("2.0"), isJsonRpcId(message["id"]) else { return false }
    if message["result"] != nil { return message["error"] == nil }
    return message["error"]?["code"]?.doubleValue != nil && message["error"]?["message"]?.stringValue != nil
}
public func parseJsonRpcMessage(_ value: JsonValue) throws -> JsonObject {
    guard let object = value.objectValue, isJsonRpcRequest(object) || isJsonRpcNotification(object) || isJsonRpcResponse(object) else { throw McpError(-32600, "Invalid JSON-RPC message") }
    return object
}
