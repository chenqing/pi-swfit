#if os(macOS)
import SwiftUI
import AppKit

struct SidebarResizeHandle: View {
    @Binding var width: Double
    let maximum: Double
    @State private var start: Double?
    @State private var hovered = false
    var body: some View {
        Rectangle().fill(.primary.opacity(hovered || start != nil ? 0.16 : 0))
            .frame(width: 4).contentShape(Rectangle())
            .onHover { value in
                hovered = value
                if value { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                if start == nil { start = min(maximum, width) }
                width = min(maximum, max(200, (start ?? width) + value.translation.width))
            }.onEnded { _ in start = nil })
            .onTapGesture(count: 2) { width = 232 }
            .accessibilityElement().accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(min(width, maximum))) points")
            .accessibilityAdjustableAction { direction in
                width = min(maximum, max(200, min(width, maximum) + (direction == .increment ? 16 : -16)))
            }.help("Drag to resize sidebar · Double-click to reset")
    }
}
#endif
