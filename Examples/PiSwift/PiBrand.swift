import SwiftUI
#if os(macOS)
import AppKit

/// Celadon: a deep jade accent on paper, pale jade on ink.
enum PiBrand {
    @MainActor static let icon: NSImage = {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage(size: NSSize(width: 32, height: 32)) }
        return image
    }()
    static let accent = adaptive(light: 0x216B5E, dark: 0xA8D8C8)
    static let onAccent = adaptive(light: 0xF4F5EF, dark: 0x163C32)
    static let sidebar = adaptive(light: 0xF1F3EF, dark: 0x141917)
    static let canvas = adaptive(light: 0xFBFCFA, dark: 0x181E1C)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}
#endif
