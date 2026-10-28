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
            if !message.text.isEmpty {
                Button(action: copyMessage) {
                    ChatIcon(copied ? .check : .copy, size: 14)
                        .frame(width: 28, height: 24).contentShape(Rectangle())
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
                if message.role == .user {
                    Text(verbatim: message.text).font(theme.bodyFont).lineSpacing(4)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownMessage(message.text)
                }
            }
            ForEach(message.tools) { tool in ToolCallView(tool: tool) }
        }
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
    private var symbol: ChatSymbol {
        switch tool.state {
        case .pending: .waiting
        case .awaitingApproval: .approval
        case .running: .waiting
        case .succeeded: .check
        case .failed: .failure
        case .denied: .approval
        case .interrupted: .interrupted
        }
    }
    private var status: String { tool.state == .awaitingApproval ? "Needs approval" : tool.state.rawValue.capitalized }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Group {
                        if tool.state == .running { ProgressView().controlSize(.mini) }
                        else { ChatIcon(symbol, size: 13) }
                    }.frame(width: 16, height: 16)
                    Text(tool.name).font(.system(size: 13))
                    if tool.state != .succeeded {
                        Text("· " + status).font(.system(size: 12))
                    }
                    ChatIcon(.right, size: 10)
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
                    if let diff = tool.diff {
                        Text("Changes").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        ScrollView([.horizontal, .vertical]) {
                            DiffText(diff: diff)
                        }.frame(height: min(240, CGFloat(diff.components(separatedBy: "\n").count) * 17 + 8))
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
