// Port: packages/mcp/src/protocol/content.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
import PiAI

public func toLlmContent(_ result: JsonObject) -> [UserContent] {
    var content: [UserContent] = (result["content"]?.arrayValue ?? []).map { block in
        switch block["type"]?.stringValue {
        case "text": return .text(.init(text: block["text"]?.stringValue ?? ""))
        case "image": return .image(.init(data: block["data"]?.stringValue ?? "", mimeType: block["mimeType"]?.stringValue ?? ""))
        case "audio": return .text(.init(text: "[audio \(block["mimeType"]?.stringValue ?? "undefined") omitted]"))
        case "resource_link": return .text(.init(text: "\(block["name"]?.stringValue ?? "undefined"): \(block["uri"]?.stringValue ?? "undefined")"))
        case "resource":
            let resource = block["resource"] ?? .emptyObject
            if let text = resource["text"]?.stringValue { return .text(.init(text: text)) }
            if let mime = resource["mimeType"]?.stringValue, mime.hasPrefix("image/") {
                return .image(.init(data: resource["blob"]?.stringValue ?? "", mimeType: mime))
            }
            return .text(.init(text: "[binary resource \(resource["uri"]?.stringValue ?? "undefined") (\(resource["mimeType"]?.stringValue ?? "unknown type")) omitted]"))
        default: return .text(.init(text: "[unsupported MCP content \(block["type"]?.stringValue ?? "undefined")]"))
        }
    }
    if content.isEmpty, let structured = result["structuredContent"] { content.append(.text(.init(text: structured.serialized()))) }
    return content
}
