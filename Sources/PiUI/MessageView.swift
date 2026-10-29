import SwiftUI
import PiChat
#if os(macOS)
import AppKit

public struct MessageView: View {
    public let message: ChatMessage
    private let openChange: ((RecordedChange) -> Void)?
    @Environment(\.chatTheme) private var theme
    @Environment(\.showsMessageActions) private var showsActions
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var copied = false
    @State private var hovered = false
    @FocusState private var copyFocused: Bool
    public init(message: ChatMessage, openChange: ((RecordedChange) -> Void)? = nil) { self.message = message; self.openChange = openChange }
    public var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if message.role == .user {
                UserBubbleLayout {
                    messageBody
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
                .overlay(alignment: .bottomTrailing) {
                    copyButton.offset(y: 28)
                }
            } else {
                messageBody.frame(maxWidth: .infinity, alignment: .leading)
            }
            if message.role == .assistant && showsActions && !message.text.isEmpty {
                copyButton
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "Your message" : "Assistant message")
        .accessibilityAction(named: Text("Copy message"), copyMessage)
        .contextMenu { if !message.text.isEmpty { Button("Copy message", action: copyMessage) } }
    }
    private var copyButton: some View {
        Button(action: copyMessage) {
            ChatIcon(copied ? .check : .copy, size: 14)
                .frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(ChatPalette.secondaryText).focused($copyFocused)
        .opacity(hovered || copied || copyFocused || contrast == .increased ? 1 : 0)
        .help("Copy message").accessibilityLabel("Copy message")
        .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
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
            if !message.tools.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(message.tools) { tool in ToolCallView(tool: tool, openChange: openChange) }
                }
            }
        }
    }
    private func copyMessage() {
        guard !message.text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copied = true
        ChatAccessibility.announce("Message copied")
    }
}

public struct ToolCallView: View {
    @Environment(\.chatTheme) private var theme
    public let tool: ChatToolCall
    private let openChange: ((RecordedChange) -> Void)?
    @State private var rawExpanded = false
    @State private var expanded = false
    public init(tool: ChatToolCall, openChange: ((RecordedChange) -> Void)? = nil) { self.tool = tool; self.openChange = openChange }
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
                    Text(tool.summary).font(.system(size: theme.codeSize)).lineLimit(1).truncationMode(.middle)
                    if let change = RecordedChange(tool: tool) {
                        Text("+\(change.added) −\(change.removed)").font(.system(size: 11)).monospacedDigit()
                    }
                    if tool.state != .succeeded {
                        Text("· " + status).font(.system(size: 12))
                    }
                    ChatIcon(.right, size: 10)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }.foregroundStyle(tool.state == .failed ? Color.red : ChatPalette.secondaryText)
                    .padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(tool.summary), \(status)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .help(expanded ? "Hide tool details" : "Show tool details")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let change = RecordedChange(tool: tool), let openChange {
                        Button { openChange(change) } label: { Label("Read recorded diff", systemImage: "doc.text") }
                            .buttonStyle(.borderless)
                    } else if let diff = tool.diff {
                        ScrollView([.horizontal, .vertical]) { DiffText(diff: diff) }.frame(maxHeight: 180)
                    }
                    DisclosureGroup("Raw arguments and result", isExpanded: $rawExpanded) {
                        ScrollView([.horizontal, .vertical]) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Arguments").foregroundStyle(ChatPalette.secondaryText)
                                Text(tool.arguments.isEmpty ? "No arguments" : tool.arguments)
                                if !tool.output.isEmpty {
                                    Text("Result").foregroundStyle(ChatPalette.secondaryText)
                                    Text(tool.output)
                                }
                            }.font(.system(size: theme.codeSize, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.frame(height: 160)
                    }.font(.system(size: 12)).foregroundStyle(ChatPalette.secondaryText)
                    if tool.state == .interrupted {
                        Text("Stopped waiting. The tool may have already taken effect.").font(.caption).foregroundStyle(ChatPalette.secondaryText)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 4)
            }
        }
    }
}
#endif
