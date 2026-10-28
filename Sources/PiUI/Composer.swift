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
    @State private var focused = false
    @State private var editorHeight: CGFloat = 28
    @State private var addingContent = false
    @FocusState private var fallbackFocused: Bool
    @Environment(\.chatTheme) private var theme
    public init(text: Binding<String>, isRunning: Bool, context: ComposerContext? = nil, send: @escaping () -> Void, stop: @escaping () -> Void) {
        _text = text; self.isRunning = isRunning; self.context = context; self.send = send; self.stop = stop
    }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                if let context {
                    Button { addingContent.toggle() } label: {
                        Image(systemName: "plus").font(.system(size: 18, weight: .regular))
                            .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(ComposerControlStyle()).foregroundStyle(.secondary)
                        .help("Add content").accessibilityLabel("Add content")
                        .popover(isPresented: $addingContent, arrowEdge: .top) {
                            Button {
                                addingContent = false
                                context.addTextFile()
                            } label: {
                                Label("Insert text file…", systemImage: "doc.text")
                                    .font(.system(size: 13)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(ComposerControlStyle()).padding(5).frame(width: 200)
                        }
                        .onChange(of: addingContent) { if !addingContent { focused = true } }
                }
                editor
                if isRunning {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 28, height: 28)
                            .background(.primary.opacity(0.08), in: Circle())
                    }.buttonStyle(ComposerControlStyle()).help("Stop generation").accessibilityLabel("Stop generation")
                } else if canSend {
                    Button(action: submit) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                            .foregroundStyle(theme.accentForeground).background(theme.accent, in: Circle())
                    }.buttonStyle(ComposerControlStyle())
                        .help("Send message · Return").accessibilityLabel("Send message")
                }
            }.padding(.horizontal, 8).padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 14).fill(.background)
                        .onTapGesture { focused = true; fallbackFocused = true }
                }
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(focused ? 0.20 : 0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
                .animation(.easeOut(duration: 0.15), value: focused)
            HStack(spacing: 12) {
                Text(context?.policy ?? (isRunning ? "You can prepare your next message" : "Return to send · ⇧ Return for a new line"))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false).help(context?.policy ?? "Return to send · ⇧ Return for a new line")
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
    private func submit() {
        guard canSend, !isRunning, !addingContent else { return }
        send()
        focused = true
        fallbackFocused = true
    }
    @ViewBuilder private var editor: some View {
        #if os(macOS)
        ComposerEditor(text: $text, focused: $focused, height: $editorHeight, submit: submit)
            .frame(height: editorHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Ask something…").font(.system(size: 14)).foregroundStyle(.tertiary)
                        .padding(.top, 4).allowsHitTesting(false)
                }
            }
            .help("Return to send · Shift-Return for a new line")
        #else
        TextField("Ask something…", text: $text, axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...8)
            .focused($fallbackFocused).accessibilityLabel("Message").padding(.vertical, 4)
        #endif
    }

}


private struct ComposerControlStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.10 : hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}
