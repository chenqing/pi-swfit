import PiAI
import PiAgent
import PiCodingAgent

/// JSONL event names/fields mirror the supported pi-coding-agent events (not its RPC protocol).
public func jsonEvent(_ event: AgentSessionEvent) -> JsonValue? {
    func message(_ value: AgentMessage) -> JsonValue { agentMessageToJson(value) }
    func result(_ value: AgentToolResult) -> JsonValue {
        var object: JsonObject = ["content": .array(value.content.map { item in
            switch item {
            case .text(let text): return .object(["type": "text", "text": .string(text.text)])
            case .image(let image): return .object(["type": "image", "data": .string(image.data), "mimeType": .string(image.mimeType)])
            }
        })]
        if let details = value.details { object["details"] = details }
        if let structured = value.structuredContent { object["structuredContent"] = structured }
        return .object(object)
    }
    switch event {
    case .agentStart: return ["type": "agent_start"]
    case .agentEnd(let messages, let willRetry): return ["type": "agent_end", "messages": .array(messages.map(message)), "willRetry": .bool(willRetry)]
    case .agentSettled(let aborted): return ["type": "agent_settled", "aborted": .bool(aborted)]
    case .turnStart: return ["type": "turn_start"]
    case .turnEnd(let m, let results): return ["type": "turn_end", "message": message(m), "toolResults": .array(results.map { message(.toolResult($0)) })]
    case .messageStart(let m): return ["type": "message_start", "message": message(m)]
    case .messageEnd(let m): return ["type": "message_end", "message": message(m)]
    case .messageUpdate(let m, let update):
        var delta: JsonObject = ["type": .string(update.type), "partial": message(.assistant(update.message))]
        switch update {
        case .textStart(let index, _), .thinkingStart(let index, _), .toolcallStart(let index, _): delta["contentIndex"] = .int(index)
        case .textDelta(let index, let text, _), .thinkingDelta(let index, let text, _), .toolcallDelta(let index, let text, _):
            delta["contentIndex"] = .int(index); delta["delta"] = .string(text)
        case .textEnd(let index, let text, _), .thinkingEnd(let index, let text, _):
            delta["contentIndex"] = .int(index); delta["content"] = .string(text)
        case .toolcallEnd(let index, let call, _):
            delta["contentIndex"] = .int(index); delta["toolCall"] = .object(["type": "toolCall", "id": .string(call.id), "name": .string(call.name), "arguments": .object(call.arguments)])
        case .done(let reason, let m): delta["reason"] = .string(reason.rawValue); delta["message"] = message(.assistant(m))
        case .error(let reason, let m): delta["reason"] = .string(reason.rawValue); delta["error"] = message(.assistant(m))
        case .start: break
        }
        return ["type": "message_update", "message": message(m), "assistantMessageEvent": .object(delta)]
    case .toolExecutionStart(let id, let name, let args): return ["type": "tool_execution_start", "toolCallId": .string(id), "toolName": .string(name), "args": .object(args)]
    case .toolExecutionUpdate(let id, let name, let args, let partial): return ["type": "tool_execution_update", "toolCallId": .string(id), "toolName": .string(name), "args": .object(args), "partialResult": result(partial)]
    case .toolExecutionEnd(let id, let name, let r, let isError, let duration):
        var object: JsonObject = ["type": "tool_execution_end", "toolCallId": .string(id), "toolName": .string(name), "result": result(r), "isError": .bool(isError)]
        if let duration { object["durationMs"] = .int(duration) }
        return .object(object)
    case .queueUpdate(let steering, let followUp): return ["type": "queue_update", "steering": .array(steering.map(JsonValue.string)), "followUp": .array(followUp.map(JsonValue.string))]
    case .entryAppended(let entry): return ["type": "entry_appended", "entry": entry.json]
    case .compactionStart(let reason): return ["type": "compaction_start", "reason": .string(reason.rawValue)]
    case .compactionEnd(let reason, let r, let aborted, let retry, let error):
        var object: JsonObject = ["type": "compaction_end", "reason": .string(reason.rawValue), "aborted": .bool(aborted), "willRetry": .bool(retry)]
        if let error { object["errorMessage"] = .string(error) }
        if let r { object["result"] = .object(["summary": .string(r.summary), "firstKeptEntryId": r.firstKeptEntryId.map(JsonValue.string) ?? .null, "tokensBefore": .int(r.tokensBefore)]) }
        return .object(object)
    case .autoRetryStart(let attempt, let max, let delay, let error): return ["type": "auto_retry_start", "attempt": .int(attempt), "maxAttempts": .int(max), "delayMs": .int(delay), "errorMessage": .string(error)]
    case .autoRetryEnd(let success, let attempt, let error):
        var object: JsonObject = ["type": "auto_retry_end", "success": .bool(success), "attempt": .int(attempt)]
        if let error { object["finalError"] = .string(error) }; return .object(object)
    case .summarizationRetryScheduled(let attempt, let max, let delay, let error): return ["type": "summarization_retry_scheduled", "attempt": .int(attempt), "maxAttempts": .int(max), "delayMs": .int(delay), "errorMessage": .string(error)]
    case .summarizationRetryAttemptStart(let source): return ["type": "summarization_retry_attempt_start", "source": .string(source.source)]
    case .summarizationRetryFinished: return ["type": "summarization_retry_finished"]
    case .nestedToolExecution: return nil // Not produced by the initial CLI tool set; MCP is not enabled here.
    }
}

extension JsonValue {
    static func int(_ value: Int) -> JsonValue { .number(Double(value)) }
}
