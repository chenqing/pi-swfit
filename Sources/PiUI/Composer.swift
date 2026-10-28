import SwiftUI

public struct Composer: View {
    @Binding private var text: String
    private let isRunning: Bool
    private let send: () -> Void
    private let stop: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.chatTheme) private var theme
    public init(text: Binding<String>, isRunning: Bool, send: @escaping () -> Void, stop: @escaping () -> Void) {
        _text = text; self.isRunning = isRunning; self.send = send; self.stop = stop
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask something…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(theme.bodyFont).lineLimit(1...8)
                    .focused($focused).accessibilityLabel("Message").padding(.vertical, 7)
                if isRunning {
                    Button(action: stop) { Image(systemName: "stop.fill").frame(width: 10, height: 18) }
                        .buttonStyle(ChatButtonStyle()).help("Stop generation").accessibilityLabel("Stop generation")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").frame(width: 10, height: 18) }
                        .buttonStyle(ChatButtonStyle(.primary)).keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send message").accessibilityLabel("Send message")
                }
            }.padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
                .background(.background, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
                    .strokeBorder(focused ? theme.accent.opacity(0.45) : Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
                .animation(.easeOut(duration: 0.15), value: focused)
            Text(isRunning ? "You can prepare your next message" : "⌘ Return to send")
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 4)
        }
    }
}
