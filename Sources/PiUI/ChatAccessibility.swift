import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
enum ChatAccessibility {
    static func announce(_ message: String) {
        #if os(macOS)
        guard !message.isEmpty, let window = NSApp?.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        #endif
    }
}
