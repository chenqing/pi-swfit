import SwiftUI
import PiChat
#if os(macOS)
import AppKit

public struct MessageView: View {
    public let message: ChatMessage
    @Environment(\.chatTheme) private var theme
    @State private var copied = false
    @State private var hovered = false
    @FocusState private var copyFocused: Bool
    public init(message: ChatMessage) { self.message = message }
    public var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if message.role == .user {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 48)
                    messageBody
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
            } else {
                messageBody.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.text.isEmpty && message.tools.isEmpty {
                Button(action: copyMessage) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11)).frame(width: 24, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).focused($copyFocused)
                .opacity(hovered || copied || copyFocused ? 1 : 0)
                .help("Copy message").accessibilityLabel("Copy message")
                .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "Your message" : "Assistant message")
        .accessibilityAction(named: Text("Copy message"), copyMessage)
        .contextMenu { if !message.text.isEmpty { Button("Copy message", action: copyMessage) } }
    }
    private var messageBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.text.isEmpty {
                // Paragraph spacing is independent of line leading. Hosts can supply a full block renderer.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text((try? AttributedString(markdown: paragraph, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(paragraph))
                            .font(theme.bodyFont).lineSpacing(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(message.tools) { tool in ToolCallView(tool: tool) }
        }
    }
    private var paragraphs: [String] {
        message.role == .user ? [message.text] : message.text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }
    private func copyMessage() {
        guard !message.text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copied = true
    }
}

public struct ToolCallView: View {
    public let tool: ChatToolCall
    @State private var expanded = false
    public init(tool: ChatToolCall) { self.tool = tool }
    private var symbol: String {
        switch tool.state {
        case .pending: "clock"
        case .awaitingApproval: "hand.raised"
        case .running: "gearshape.2"
        case .succeeded: "checkmark"
        case .failed: "exclamationmark.circle"
        case .denied: "hand.raised"
        case .interrupted: "pause.circle"
        }
    }
    private var status: String { tool.state == .awaitingApproval ? "Needs approval" : tool.state.rawValue.capitalized }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 11)).frame(width: 14)
                    Text(tool.name).font(.system(size: 13))
                    if tool.state != .succeeded {
                        Text("· " + status).font(.system(size: 12))
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }.foregroundStyle(tool.state == .failed ? Color.red : .secondary)
                    .padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(tool.name), \(status)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .help(expanded ? "Hide tool details" : "Show tool details")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Arguments").font(.caption).foregroundStyle(.secondary)
                    Text(tool.arguments.isEmpty ? "No arguments" : tool.arguments)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if !tool.output.isEmpty {
                        Text("Result").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        Text(tool.output).font(.system(size: 13)).textSelection(.enabled)
                    }
                    if tool.state == .interrupted {
                        Text("Stopped waiting. The tool may have already taken effect.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 4)
            }
        }
    }
}
#endif
