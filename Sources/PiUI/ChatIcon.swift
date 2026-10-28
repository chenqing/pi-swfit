import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shared action vocabulary. Keep symbol size separate from the control's hit area.
public enum ChatSymbol: String {
    case add = "plus"
    case search = "magnifyingglass"
    case close = "xmark"
    case sidebar = "sidebar.left"
    case settings = "gearshape"
    case more = "ellipsis"
    case copy = "square.on.square"
    case check = "checkmark"
    case send = "return"
    case stop = "stop.fill"
    case down = "chevron.down"
    case right = "chevron.right"
    case latest = "arrow.down"
    case file = "doc.text"
    case approval = "hand.raised"
    case waiting = "clock"
    case failure = "exclamationmark.circle"
    case interrupted = "pause.circle"
}

public struct ChatIcon: View {
    private let symbol: ChatSymbol
    private let size: CGFloat
    public init(_ symbol: ChatSymbol, size: CGFloat = 16) {
        self.symbol = symbol; self.size = size
    }
    public var body: some View {
        glyph
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .accessibilityHidden(true)
    }
}

private extension ChatIcon {
    @ViewBuilder var glyph: some View {
        if symbol == .more {
            #if os(macOS)
            // AppKit menu buttons extract the image, dropping SwiftUI rotation modifiers.
            Image(nsImage: Self.moreImage).resizable().frame(width: size, height: size)
            #else
            Image(systemName: "ellipsis").rotationEffect(.degrees(90))
            #endif
        } else { Image(systemName: symbol.rawValue) }
    }
    #if os(macOS)
    static let moreImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for y in [3.0, 8.0, 13.0] {
                NSBezierPath(ovalIn: NSRect(x: 8, y: y, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
    #endif
}
