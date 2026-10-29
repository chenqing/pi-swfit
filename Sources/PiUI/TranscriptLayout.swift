import SwiftUI
import PiChat

/// Presentation only: keep event IDs and tool order intact for search and disclosures.
struct TranscriptRow: Identifiable {
    let message: ChatMessage
    let spacingBefore: CGFloat
    let showsActions: Bool
    var id: UUID { message.id }

    static func make(_ messages: [ChatMessage], isRunning: Bool = false) -> [Self] {
        let visible = messages.filter { !$0.text.isEmpty || !$0.tools.isEmpty }
        return visible.indices.map { index in
            let message = visible[index]
            let previous = index > 0 ? visible[index - 1] : nil
            let next = index + 1 < visible.count ? visible[index + 1] : nil
            let spacing: CGFloat
            if let previous {
                if message.role == .user { spacing = 32 }
                else if previous.role == .user { spacing = 24 }
                else if message.text.isEmpty && !previous.tools.isEmpty { spacing = 4 }
                else { spacing = 12 }
            } else { spacing = 0 }
            return Self(message: message, spacingBefore: spacing,
                        showsActions: message.role == .assistant && next?.role != .assistant && !(isRunning && next == nil))
        }
    }
}

private struct MessageActionsKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var showsMessageActions: Bool {
        get { self[MessageActionsKey.self] }
        set { self[MessageActionsKey.self] = newValue }
    }
}

#if os(macOS)
/// Content-sized bubbles, capped at 85% of the reading column without a height-measuring reader.
struct UserBubbleLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        let width = proposal.width ?? bubble.sizeThatFits(.unspecified).width
        let size = bubble.sizeThatFits(ProposedViewSize(width: width * 0.85, height: nil))
        return CGSize(width: width, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                              proposal: ProposedViewSize(width: bounds.width * 0.85, height: nil))
    }
}
#endif
