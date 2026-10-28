import SwiftUI

/// Host-owned controls; the composer does not choose models or alter tool permissions.
public struct ComposerContext {
    public var model: String
    public var policy: String
    public var configure: () -> Void
    public var addTextFile: () -> Void
    public init(model: String, policy: String, configure: @escaping () -> Void, addTextFile: @escaping () -> Void) {
        self.model = model; self.policy = policy; self.configure = configure; self.addTextFile = addTextFile
    }
}

public struct Composer: View {
    @Binding private var text: String
    private let isRunning: Bool
    private let send: () -> Void
    private let stop: () -> Void
    private let context: ComposerContext?
    @FocusState private var focused: Bool
    @Environment(\.chatTheme) private var theme
    public init(text: Binding<String>, isRunning: Bool, context: ComposerContext? = nil, send: @escaping () -> Void, stop: @escaping () -> Void) {
        _text = text; self.isRunning = isRunning; self.context = context; self.send = send; self.stop = stop
    }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                if let context {
                    Menu {
                        Button("Insert text file…", systemImage: "doc.text", action: context.addTextFile)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 16, weight: .regular)).frame(width: 24, height: 28)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .tint(.secondary).foregroundStyle(.secondary).help("Insert text file").accessibilityLabel("Add content")
                }
                TextField("Ask something…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...8)
                    .focused($focused).accessibilityLabel("Message").padding(.vertical, 4)
                    .help("⌘ Return to send · Return for a new line")
                if isRunning {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 28, height: 28)
                            .background(.primary.opacity(0.08), in: Circle())
                    }.buttonStyle(.plain).help("Stop generation").accessibilityLabel("Stop generation")
                } else if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                            .foregroundStyle(theme.accentForeground).background(theme.accent, in: Circle())
                    }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                        .help("Send message · ⌘ Return").accessibilityLabel("Send message")
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(focused ? 0.20 : 0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
                .animation(.easeOut(duration: 0.15), value: focused)
            HStack(spacing: 12) {
                Text(context?.policy ?? (isRunning ? "You can prepare your next message" : "⌘ Return to send"))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false).help(context?.policy ?? "⌘ Return to send")
                Spacer(minLength: 8)
                if let context {
                    Button(action: context.configure) {
                        HStack(spacing: 4) {
                            Text(context.model).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                        }.frame(maxWidth: 220, alignment: .trailing).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(isRunning)
                        .help("Model & workspace · \(context.model)").accessibilityLabel("Model: \(context.model)")
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(minHeight: 20)
        }
    }
}
