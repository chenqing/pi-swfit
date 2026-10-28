import SwiftUI
import PiChat
#if os(macOS)
import AppKit

/// Use the default message renderer or supply your own Markdown, tool and attachment views.
public struct ConversationView<MessageContent: View>: View {
    @Bindable private var session: ChatSession
    private let renderMessage: (ChatMessage) -> MessageContent
    private let brandIcon: Image?
    private let composerContext: ComposerContext?
    @Environment(\.chatTheme) private var theme
    @State private var followsBottom = true
    @State private var distance: CGFloat = 0
    public init(session: ChatSession, brandIcon: Image? = nil, composerContext: ComposerContext? = nil, @ViewBuilder message: @escaping (ChatMessage) -> MessageContent) {
        self.session = session; self.brandIcon = brandIcon; self.composerContext = composerContext; renderMessage = message
    }
    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if session.messages.isEmpty { emptyState.padding(.top, 36) }
                            ForEach(session.displayedMessages) { message in renderMessage(message).id(message.id) }
                            if session.isRunning && session.approvals.pending.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(session.state == .stopping ? "Stopping…" : "Working…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24).frame(maxWidth: theme.contentWidth).frame(maxWidth: .infinity)
                            .background(ScrollMetrics { remaining, movedUp in
                                distance = remaining
                                if movedUp { followsBottom = false }
                                if remaining < 40 { followsBottom = true }
                                else if followsBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                            })
                    }.coordinateSpace(name: "pi-conversation")
                        .onChange(of: session.messages.count) { if followsBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                        .onChange(of: session.messages.last?.text) { if followsBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                        .overlay(alignment: .bottom) {
                            if !followsBottom && distance > 80 {
                                Button { followsBottom = true; proxy.scrollTo("bottom", anchor: .bottom) } label: {
                                    ChatIcon(.latest, size: 14)
                                        .frame(width: 30, height: 30)
                                        .background(.regularMaterial, in: Circle())
                                        .overlay { Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
                                        .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help("Back to latest").accessibilityLabel("Back to latest").padding(.bottom, 8)
                            }
                        }
                }
            }
            VStack(spacing: 12) {
                ForEach(session.approvals.pending) { approval in
                    ApprovalView(approval: approval) { session.approvals.resolve(approval.id, allow: $0) }
                }
                if let error = session.error {
                    Label { Text(error) } icon: { ChatIcon(.failure, size: 14) }.font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else if session.state == .cancelled {
                    Text("Stopped · Your partial response is preserved").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                Composer(text: $session.draft, isRunning: session.isRunning, context: composerContext,
                         send: { Task { await session.send() } }, stop: { session.stop() })
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16).frame(maxWidth: theme.contentWidth).frame(maxWidth: .infinity)
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let brandIcon {
                brandIcon.resizable().interpolation(.high).frame(width: 72, height: 72).accessibilityHidden(true)
            } else {
                Text("π").font(.system(size: 42, weight: .regular, design: .serif))
                    .foregroundStyle(theme.accent).frame(width: 62, height: 62)
                    .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Room for a good idea.").font(.system(size: 28, weight: .medium, design: .rounded)).tracking(-0.6)
                Text("A conversation, a few useful tools, and you in control.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
            }
            VStack(alignment: .leading, spacing: 8) {
                suggestion("Walk me through the architecture", symbol: "square.stack.3d.up")
                suggestion("Help me explore an idea", symbol: "lightbulb")
            }.padding(.top, 8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 30)
    }
    private func suggestion(_ text: String, symbol: String) -> some View {
        Button { session.draft = text } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular)).foregroundStyle(.secondary).frame(width: 18)
                Text(text).font(.system(size: 13))
                Spacer()
                Image(systemName: "arrow.up.left").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(.vertical, 4).frame(maxWidth: 330, alignment: .leading)
        }.buttonStyle(ChatButtonStyle())
    }

}
public extension ConversationView where MessageContent == MessageView {
    init(session: ChatSession, brandIcon: Image? = nil, composerContext: ComposerContext? = nil) {
        self.init(session: session, brandIcon: brandIcon, composerContext: composerContext) { MessageView(message: $0) }
    }
}

private struct ScrollMetrics: NSViewRepresentable {
    let changed: (CGFloat, Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { let view = ObserverView(); view.changed = changed; return view }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.changed = changed
        DispatchQueue.main.async { [weak view] in view?.connect(); view?.measure() }
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.disconnect() }
    final class ObserverView: NSView {
        var changed: ((CGFloat, Bool) -> Void)?
        private weak var scroll: NSScrollView?
        private var tokens: [NSObjectProtocol] = []
        private var lastTop: CGFloat?
        private var lastRemaining: CGFloat?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { disconnect() }
            else { DispatchQueue.main.async { [weak self] in self?.connect(); self?.measure() } }
        }
        func connect() {
            guard scroll == nil, let enclosing = enclosingScrollView, let document = enclosing.documentView else { return }
            scroll = enclosing
            enclosing.contentView.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.boundsDidChangeNotification, enclosing.contentView), (NSView.frameDidChangeNotification, document)] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.measure() }
                })
            }
        }
        func measure() {
            guard let scroll, let document = scroll.documentView else { return }
            let visible = scroll.documentVisibleRect
            let top = document.isFlipped ? visible.minY : -visible.maxY
            let remaining = max(0, document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY)
            let movedUp = lastTop.map { top < $0 - 1 } ?? false
            let differs = lastRemaining.map { abs(remaining - $0) > 0.5 } ?? true
            lastTop = top; lastRemaining = remaining
            if differs || movedUp { changed?(remaining, movedUp) }
        }
        func disconnect() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll(); scroll = nil; lastTop = nil; lastRemaining = nil
        }
    }
}
#endif
