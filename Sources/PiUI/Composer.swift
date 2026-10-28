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
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask something…", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(theme.bodyFont).lineLimit(2...8).focused($focused).accessibilityLabel("Message")
            HStack {
                Text(isRunning ? "You can prepare your next message" : "⌘ Return to send")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if isRunning {
                    Button(action: stop) { Image(systemName: "stop.fill").frame(width: 10, height: 18) }
                        .buttonStyle(ChatButtonStyle()).help("Stop generation").accessibilityLabel("Stop generation")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").frame(width: 10, height: 18) }
                        .buttonStyle(ChatButtonStyle(.primary)).keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send message").accessibilityLabel("Send message")
                }
            }
        }.padding(16).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).strokeBorder(focused ? theme.accent.opacity(0.45) : Color.primary.opacity(0.10), lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
