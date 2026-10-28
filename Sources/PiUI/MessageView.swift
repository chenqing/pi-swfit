import SwiftUI
import PiChat
#if os(macOS)
import AppKit

public struct MessageView: View {
    public let message: ChatMessage
    @Environment(\.chatTheme) private var theme
    @State private var copied = false
    @State private var hovered = false
    public init(message: ChatMessage) { self.message = message }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !message.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        copied = true
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovered || copied ? 1 : 0.55).help("Copy message").accessibilityLabel("Copy message")
                    .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
                }
            }
            if !message.text.isEmpty {
                // Inline Markdown preserves source line breaks. Hosts can inject a full block renderer.
                Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                    .font(theme.bodyFont).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(message.tools) { tool in ToolCallView(tool: tool) }
        }
        .padding(message.role == .user ? 16 : 2)
        .background(message.role == .user ? Color.primary.opacity(0.025) : .clear, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
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
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .denied: "hand.raised"
        case .interrupted: "pause.circle"
        }
    }
    public var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Arguments").font(.caption).foregroundStyle(.secondary)
                Text(tool.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if !tool.output.isEmpty {
                    Text("Result").font(.caption).foregroundStyle(.secondary)
                    Text(tool.output).font(.system(size: 13)).textSelection(.enabled)
                }
                if tool.state == .interrupted {
                    Text("Stopped waiting. The tool may have already taken effect.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            Label { HStack { Text(tool.name); Spacer(); Text(tool.state == .awaitingApproval ? "Needs approval" : tool.state.rawValue.capitalized).foregroundStyle(.secondary) } } icon: { Image(systemName: symbol) }
                .font(.system(size: 12))
        }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
