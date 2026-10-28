import Foundation
import PiAI
import PiAgent

// Port of packages/agent/test/utils/get-current-time.ts

func getCurrentTime(_ timezone: String? = nil) throws -> AgentToolResult {
    let date = Date()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateStyle = .full
    formatter.timeStyle = .long
    if let timezone {
        guard let zone = TimeZone(identifier: timezone) else {
            throw PiError("Invalid timezone: \(timezone). Current UTC time: \(ISO8601DateFormatter().string(from: date))")
        }
        formatter.timeZone = zone
    }
    return AgentToolResult(
        content: [.text(TextContent(text: formatter.string(from: date)))],
        details: ["utcTimestamp": .number((date.timeIntervalSince1970 * 1000).rounded(.down))]
    )
}

let getCurrentTimeSchema: JsonValue = [
    "type": "object",
    "properties": [
        "timezone": ["type": "string", "description": "Optional timezone (e.g., 'America/New_York', 'Europe/London')"],
    ],
]

let getCurrentTimeTool = AgentTool(
    name: "get_current_time",
    label: "Current Time",
    description: "Get the current date and time",
    parameters: getCurrentTimeSchema
) { _, args, _, _ in
    try getCurrentTime(args["timezone"]?.stringValue)
}
