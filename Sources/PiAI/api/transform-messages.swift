import Foundation

// Port of packages/ai/src/api/transform-messages.ts.

private let NON_VISION_USER_IMAGE_PLACEHOLDER = "(image omitted: model does not support images)"
private let NON_VISION_TOOL_IMAGE_PLACEHOLDER = "(tool image omitted: model does not support images)"
private let ERROR_TOOL_IMAGE_PLACEHOLDER = "(image attached after the tool results)"

/** An error tool result split into a text-only result and the images to send after the tool results. */
public struct SplitErrorToolResult: Sendable, Hashable {
	/** The result content with each run of images replaced by a note. */
	public var content: [TextContent]
	/** Text naming the tool call, to send before `images`. */
	public var caption: String
	public var images: [ImageContent]
	public init(content: [TextContent], caption: String, images: [ImageContent]) {
		self.content = content
		self.caption = caption
		self.images = images
	}
}

/**
 * Split the images out of an error tool result, for APIs that reject images in error results
 * (Anthropic, and Claude on Bedrock). Send the returned content as the tool result and the caption and
 * images after all tool results of the turn, in the same user message. Returns undefined for results
 * that need no split (#10794).
 */
public func splitErrorToolResultImages(_ msg: ToolResultMessage) -> SplitErrorToolResult? {
	if !msg.isError { return nil }
	let images = msg.content.compactMap { $0.imageContent }
	if images.isEmpty { return nil }
	return SplitErrorToolResult(
		content: replaceImagesWithPlaceholder(msg.content, ERROR_TOOL_IMAGE_PLACEHOLDER),
		caption: "Images from the error result of tool call \(msg.toolCallId) (\(msg.toolName)):",
		images: images
	)
}

private func replaceImagesWithPlaceholder(_ content: [UserContent], _ placeholder: String) -> [TextContent] {
	var result: [TextContent] = []
	var previousWasPlaceholder = false

	for block in content {
		switch block {
		case .image:
			if !previousWasPlaceholder {
				result.append(TextContent(text: placeholder))
			}
			previousWasPlaceholder = true
			continue
		case .text(let text):
			result.append(text)
			previousWasPlaceholder = text.text == placeholder
		}
	}

	return result
}

private func downgradeUnsupportedImages(_ messages: [Message], _ model: Model) -> [Message] {
	if model.input.contains("image") {
		return messages
	}

	return messages.map { msg in
		if case .user(var user) = msg, case .blocks(let blocks) = user.content {
			user.content = .blocks(replaceImagesWithPlaceholder(blocks, NON_VISION_USER_IMAGE_PLACEHOLDER).map { .text($0) })
			return .user(user)
		}

		if case .toolResult(var toolResult) = msg {
			toolResult.content = replaceImagesWithPlaceholder(toolResult.content, NON_VISION_TOOL_IMAGE_PLACEHOLDER).map { .text($0) }
			return .toolResult(toolResult)
		}

		return msg
	}
}

/**
 * Normalize tool call ID for cross-provider compatibility.
 * OpenAI Responses API generates IDs that are 450+ chars with special characters like `|`.
 * Anthropic APIs require IDs matching ^[a-zA-Z0-9_-]+$ (max 64 chars).
 */
public func transformMessages(
	_ messages: [Message],
	_ model: Model,
	_ normalizeToolCallId: ((String, Model, AssistantMessage) -> String)? = nil
) -> [Message] {
	// Build a map of original tool call IDs to normalized IDs
	var toolCallIdMap: [String: String] = [:]
	// Not ported: null/undefined content normalization (Swift message content is non-optional).
	let imageAwareMessages = downgradeUnsupportedImages(messages, model)

	// First pass: transform messages (unsupported image downgrade, thinking blocks, tool call ID normalization)
	let transformed: [Message] = imageAwareMessages.map { msg in
		switch msg {
		// System and user messages pass through unchanged
		case .system, .user:
			return msg

		// Handle toolResult messages - normalize toolCallId if we have a mapping
		case .toolResult(var toolResult):
			if let normalizedId = toolCallIdMap[toolResult.toolCallId], !normalizedId.isEmpty, normalizedId != toolResult.toolCallId {
				toolResult.toolCallId = normalizedId
				return .toolResult(toolResult)
			}
			return msg

		// Assistant messages need transformation check
		case .assistant(var assistantMsg):
			let isSameModel =
				assistantMsg.provider == model.provider &&
				assistantMsg.api == model.api &&
				assistantMsg.model == model.id

			let transformedContent: [AssistantContent] = assistantMsg.content.flatMap { block -> [AssistantContent] in
				switch block {
				case .thinking(let thinking):
					// Thinking from another model is dropped. Signatures and encrypted reasoning are
					// only valid for the model that produced them, and sending readable thinking as
					// plain text makes the new model treat it as part of the visible reply.
					if !isSameModel { return [] }
					// Keep redacted and signed blocks even if the thinking text is empty
					// (OpenAI encrypted reasoning); they are needed for replay.
					if thinking.redacted == true || thinking.thinkingSignature?.isEmpty == false { return [block] }
					if thinking.thinking.isEmpty || jsTrim(thinking.thinking) == "" { return [] }
					return [block]

				case .text(let text):
					if isSameModel { return [block] }
					return [.text(TextContent(text: text.text))]

				case .toolCall(let toolCall):
					var normalizedToolCall = toolCall

					if !isSameModel && toolCall.thoughtSignature?.isEmpty == false {
						normalizedToolCall.thoughtSignature = nil
					}

					if !isSameModel, let normalizeToolCallId {
						let normalizedId = normalizeToolCallId(toolCall.id, model, assistantMsg)
						if normalizedId != toolCall.id {
							toolCallIdMap[toolCall.id] = normalizedId
							normalizedToolCall.id = normalizedId
						}
					}

					return [.toolCall(normalizedToolCall)]
				}
			}

			assistantMsg.content = transformedContent
			return .assistant(assistantMsg)
		}
	}

	// Second pass: insert synthetic empty tool results for orphaned tool calls
	// This preserves thinking signatures and satisfies API requirements
	var result: [Message] = []
	var pendingToolCalls: [ToolCall] = []
	var existingToolResultIds = Set<String>()
	// System messages are transparent to tool-call accounting: one that lands between a tool
	// call and its results is held back and emitted after the results (synthetic ones
	// included), so it never causes a duplicate result for a call that is answered later.
	var heldSystemMessages: [Message] = []
	func closePendingToolCalls() {
		if !pendingToolCalls.isEmpty {
			for tc in pendingToolCalls where !existingToolResultIds.contains(tc.id) {
				result.append(.toolResult(ToolResultMessage(
					toolCallId: tc.id,
					toolName: tc.name,
					content: [.text(TextContent(text: "No result provided"))],
					isError: true,
					timestamp: dateNow()
				)))
			}
			pendingToolCalls = []
			existingToolResultIds = Set()
		}
		result.append(contentsOf: heldSystemMessages)
		heldSystemMessages.removeAll()
	}

	for msg in transformed {
		switch msg {
		case .assistant(let assistantMsg):
			// If we have pending orphaned tool calls from a previous assistant, insert synthetic results now
			closePendingToolCalls()

			// Skip errored/aborted assistant messages entirely.
			// These are incomplete turns that shouldn't be replayed:
			// - May have partial content (reasoning without message, incomplete tool calls)
			// - Replaying them can cause API errors (e.g., OpenAI "reasoning without following item")
			// - The model should retry from the last valid state
			if assistantMsg.stopReason == .error || assistantMsg.stopReason == .aborted {
				continue
			}

			// Track tool calls from this assistant message
			let toolCalls = assistantMsg.content.compactMap { $0.toolCallContent }
			if !toolCalls.isEmpty {
				pendingToolCalls = toolCalls
				existingToolResultIds = Set()
			}

			result.append(msg)
		case .toolResult(let toolResult):
			existingToolResultIds.insert(toolResult.toolCallId)
			result.append(msg)
		case .system:
			if !pendingToolCalls.isEmpty {
				heldSystemMessages.append(msg)
			} else {
				result.append(msg)
			}
		case .user:
			// A new user turn interrupts tool flow - insert synthetic results for orphaned calls
			closePendingToolCalls()
			result.append(msg)
		}
	}

	// If the conversation ends with unresolved tool calls, synthesize results now.
	closePendingToolCalls()

	return result
}
