// Port of extensions/mcp/tools.ts (non-TUI portions) @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
import Foundation
import CryptoKit
import PiAI
import PiAgent
import PiMCP

public func createMcpToolName(server: String, tool: String, isTaken: (String) -> Bool = { _ in false }) -> String {
    let name = "mcp__\(server)__\(tool)".replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
    if name.count <= 64 && !isTaken(name) { return name }
    let hash = SHA256.hash(data: Data((server + "\0" + tool).utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    return String(name.prefix(55)) + "_" + hash
}

private func relocateMcpSchema(_ value: JsonValue) -> JsonValue {
    if let array = value.arrayValue { return .array(array.map(relocateMcpSchema)) }
    guard let object = value.objectValue else { return value }
    var result = JsonObject()
    for (key, value) in object {
        if key == "$ref", let ref = value.stringValue, ref == "#" || ref.hasPrefix("#/") {
            result[key] = .string("#/properties/structuredContent" + ref.dropFirst())
        } else if ["const", "enum", "default", "examples"].contains(key) { result[key] = value }
        else if ["properties", "patternProperties", "dependentSchemas", "dependencies", "$defs", "definitions"].contains(key), let schemas = value.objectValue {
            var relocated = JsonObject()
            for (name, schema) in schemas { relocated[name] = relocateMcpSchema(schema) }
            result[key] = .object(relocated)
        } else { result[key] = relocateMcpSchema(value) }
    }
    return .object(result)
}

public func createMcpResultSchema(_ structuredContentSchema: JsonValue? = nil) -> JsonValue {
    .object(["type": .string("object"), "properties": .object([
        "content": .object(["type": .string("array"), "items": .object([
            "type": .string("object"), "properties": .object([
                "type": .object(["enum": .array(["text", "image", "audio", "resource_link", "resource"].map(JsonValue.string))]),
                "text": .object(["type": .string("string")]), "data": .object(["type": .string("string")]),
                "mimeType": .object(["type": .string("string")])]),
            "required": .array([.string("type")]), "additionalProperties": .bool(true)])]),
        "structuredContent": structuredContentSchema.map(relocateMcpSchema) ?? .emptyObject,
        "isError": .object(["type": .string("boolean")])]),
        "required": .array([.string("content")]), "additionalProperties": .bool(true)])
}

public let MCP_OUTPUT_MAX_BYTES = 20 * 1024
public typealias McpOutputSaver = @Sendable (Data, String) throws -> String
public func saveMcpOutput(_ data: Data, _ suffix: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mcp-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    let path = directory.appendingPathComponent("output" + suffix)
    try data.write(to: path, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    return path.path
}

public func convertMcpResult(server: String, tool: String, result: JsonObject,
                             saveOutput: McpOutputSaver = saveMcpOutput) -> AgentToolResult {
    var content: [UserContent] = []
    for block in result["content"]?.arrayValue ?? [] {
        let resource = block["resource"]
        let mime = resource?["mimeType"]?.stringValue ?? ""
        if block["type"] == .string("resource"), let blob = resource?["blob"]?.stringValue, !mime.hasPrefix("image/") {
            let uri = resource?["uri"]?.stringValue ?? "unknown"
            if let data = Data(base64Encoded: blob) {
                let type = mime.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
                if type.hasPrefix("text/") || type == "application/json" || type.hasSuffix("+json") || type.hasSuffix("+xml") {
                    content.append(.text(.init(text: String(decoding: data, as: UTF8.self))))
                } else {
                    let ext = URL(string: uri)?.pathExtension ?? ""
                    let suffix = ext.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) != nil ? "." + ext : ".bin"
                    do { content.append(.text(.init(text: "[Binary resource \(uri) (\(mime), \(data.count) bytes) saved to \(try saveOutput(data, suffix))]"))) }
                    catch { content.append(.text(.init(text: "[Binary resource \(uri) could not be saved]"))) }
                }
            } else { content.append(.text(.init(text: "[Binary resource \(uri) has invalid base64 data]"))) }
        } else { content += toLlmContent(["content": .array([block])]) }
    }
    if content.isEmpty { content = toLlmContent(result) }
    var text = content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }.joined(separator: "\n")
    if result["isError"] == .bool(true), text.isEmpty {
        text = "MCP tool \(server)/\(tool) returned an error"; content.append(.text(.init(text: text)))
    }
    var details: JsonObject = ["server": .string(server), "tool": .string(tool)]
    if text.utf8.count > MCP_OUTPUT_MAX_BYTES {
        let data = Data(text.utf8)
        let budget = MCP_OUTPUT_MAX_BYTES / 2 - 256
        let head = String(decoding: data.prefix(budget), as: UTF8.self)
        let tail = String(decoding: data.suffix(budget), as: UTF8.self)
        let location: String
        do {
            let path = try saveOutput(data, ".txt"); details["fullOutputPath"] = .string(path)
            location = "Full output saved to \(path)"
        } catch { location = "Full output could not be saved" }
        content = [.text(.init(text: head + "\n\n[Output truncated]\n\n" + tail + "\n\n" + location))]
            + content.filter { if case .image = $0 { true } else { false } }
    }
    var structured = result; structured["_meta"] = nil
    return .init(content: content, details: .object(details), structuredContent: .object(structured),
                 isError: result["isError"]?.boolValue)
}
