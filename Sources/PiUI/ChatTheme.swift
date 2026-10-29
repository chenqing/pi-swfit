import SwiftUI

public struct ChatTheme: Sendable {
    public var accent: Color
    public var accentForeground: Color
    public var contentWidth: CGFloat
    public var cornerRadius: CGFloat
    public var bodyFont: Font
    public init(accent: Color = .accentColor, accentForeground: Color = .white, contentWidth: CGFloat = 816, cornerRadius: CGFloat = 12, bodyFont: Font = .system(size: 15)) {
        self.accent = accent; self.accentForeground = accentForeground; self.contentWidth = contentWidth; self.cornerRadius = cornerRadius; self.bodyFont = bodyFont
    }
}
private struct ChatThemeKey: EnvironmentKey { static let defaultValue = ChatTheme() }
public extension EnvironmentValues {
    var chatTheme: ChatTheme {
        get { self[ChatThemeKey.self] }
        set { self[ChatThemeKey.self] = newValue }
    }
}
public extension View {
    func chatTheme(_ theme: ChatTheme) -> some View { environment(\.chatTheme, theme).tint(theme.accent) }
}

public struct ChatButtonStyle: ButtonStyle {
    public enum Kind { case primary, quiet }
    public var kind: Kind
    @Environment(\.chatTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    public init(_ kind: Kind = .quiet) { self.kind = kind }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: 32)
            .foregroundStyle(kind == .primary ? theme.accentForeground : Color.primary.opacity(0.8))
            .background(kind == .primary ? theme.accent : Color.primary.opacity(hovered ? 0.075 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .onHover { hovered = $0 }
    }
}
