import SwiftUI
import PiUI
import PiChat
import PiAI
import PiAgent
#if os(macOS)
import AppKit

@main
struct PiSwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var workspace = AppWorkspace()
    var body: some Scene {
        Window("Pi Swift", id: "main") { AppView(workspace: workspace).frame(minWidth: 640, minHeight: 560).onAppear { delegate.workspace = workspace } }
            .defaultSize(width: 1024, height: 760).windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unified)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: AppWorkspace?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await workspace?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = PiBrand.icon
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppView: View {
    @Bindable var workspace: AppWorkspace
    private var session: ChatSession? { workspace.session }
    private var connection: String { workspace.connection }
    @State private var sheet: AppSheet?
    @State private var showsSidebar = true
    @State private var appearance = "system"
    @State private var insertError: String?
    private let sidebarWidth: CGFloat = 232
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let error = workspace.error {
                    HStack { Text(error).font(.callout).foregroundStyle(.red); Spacer(); Button("Dismiss") { workspace.error = nil } }.padding(12)
                }
                if let session {
                    HStack(spacing: 0) {
                        if showsSidebar {
                            ConversationSidebar(workspace: workspace, configure: { sheet = .connection })
                                .frame(width: sidebarWidth)
                        }
                        ConversationView(session: session, brandIcon: Image(nsImage: PiBrand.icon),
                                         composerContext: ComposerContext(model: workspace.profile?.modelID ?? "Offline demo", policy: "Ask before tools",
                                             configure: { sheet = .connection }, addTextFile: insertTextFile))
                            .frame(maxWidth: .infinity)
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.background {
                HStack(spacing: 0) {
                    if showsSidebar { PiBrand.sidebar.frame(width: sidebarWidth) }
                    PiBrand.canvas
                }.ignoresSafeArea(.container, edges: .top)
            }
                .toolbar {
                    ToolbarItem(placement: .navigation) { windowIdentity }
                    ToolbarItem(placement: .principal) { Spacer(minLength: 0) }
                    ToolbarItemGroup(placement: .primaryAction) { windowActions.buttonStyle(.plain) }
                }
                .toolbarBackground(headerBackground(width: geometry.size.width), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .chatTheme(ChatTheme(accent: PiBrand.accent, accentForeground: PiBrand.onAccent))
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .disabled(workspace.busy)
                .task { await workspace.start() }
                .onChange(of: session?.isRunning) { if session?.isRunning == false { workspace.remember() } }
                .sheet(item: $sheet) { destination in
                    Group {
                        switch destination {
                        case .connection: ConnectionSheet(workspace: workspace)
                        }
                    }.chatTheme(ChatTheme(accent: PiBrand.accent, accentForeground: PiBrand.onAccent))
                }
                .alert("Couldn’t insert text", isPresented: Binding(get: { insertError != nil }, set: { if !$0 { insertError = nil } })) {
                    Button("OK") { insertError = nil }
                } message: { Text(insertError ?? "") }
        }
    }
    private func headerBackground(width: CGFloat) -> LinearGradient {
        let edge = min(1, sidebarWidth / max(width, 1))
        let leading = showsSidebar ? PiBrand.sidebar : PiBrand.canvas
        return LinearGradient(stops: [
            .init(color: leading, location: 0),
            .init(color: leading, location: edge),
            .init(color: PiBrand.canvas, location: edge),
            .init(color: PiBrand.canvas, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }
    private var windowIdentity: some View {
        HStack(spacing: 12) {
            Button { showsSidebar.toggle() } label: {
                ChatIcon(.sidebar, size: 18).frame(width: 28, height: 32)
            }.buttonStyle(.plain).help("Toggle sidebar").accessibilityLabel("Toggle sidebar")
                .keyboardShortcut("s", modifiers: [.command, .control])
            Text("Pi Swift").font(.system(size: 13, weight: .medium)).help(connection)
        }.frame(height: 36).padding(.leading, 8)
    }
    private func insertTextFile() {
        let panel = NSOpenPanel()
        panel.title = "Insert text file"
        panel.prompt = "Insert"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do { try await workspace.insertTextFile(url) }
                catch { insertError = String(describing: error) }
            }
        }
    }
    @ViewBuilder private var windowActions: some View {
        if let session {
            if !showsSidebar {
                Button { Task { await workspace.newConversation() } } label: {
                    ChatIcon(.add, size: 18).frame(width: 28, height: 32)
                }.help("New conversation").accessibilityLabel("New conversation").disabled(session.isRunning)
            }
            Menu {
                Text(connection)
                if let cwd = workspace.cwd { Text(URL(fileURLWithPath: cwd).lastPathComponent) }
                Button("Show conversations", systemImage: ChatSymbol.sidebar.rawValue) { showsSidebar = true }
                Button("Model & workspace…", systemImage: ChatSymbol.settings.rawValue) { sheet = .connection }
                    .disabled(session.isRunning)
                Divider()
                Menu("Scenarios") {
                    ForEach(DemoScenario.allCases, id: \.self) { scenario in
                        Button(scenario.title) {
                            Task { await workspace.demo(scenario) }
                        }
                    }
                }.disabled(session.isRunning)
                Menu("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }.pickerStyle(.inline)
                }
            } label: { ChatIcon(.more, size: 18).frame(width: 28, height: 32) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More options").accessibilityLabel("More options")
        }
    }
}

private enum AppSheet: String, Identifiable {
    case connection
    var id: String { rawValue }
}

#else
@main struct PiSwiftApp { static func main() { print("PiSwift requires macOS.") } }
#endif
