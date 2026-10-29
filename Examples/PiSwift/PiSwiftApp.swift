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
            .defaultSize(width: 1200, height: 760).windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New conversation") { Task { await workspace.newConversation() } }
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(workspace.busy || workspace.session == nil || workspace.session?.isRunning == true)
                }
            }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: AppWorkspace?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { sender.reply(toApplicationShouldTerminate: await workspace?.shutdown() ?? true) }
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
    @AppStorage("showsConversationSidebar") private var showsSidebar = true
    @State private var windowSize = CGSize.zero
    private var detailsFit: Bool { windowSize.width >= (showsSidebar ? 1080 : 848) }
    @AppStorage("showsSessionDetails") private var showsDetails = true
    @State private var detailsExpansion = DetailsExpansion()
    @State private var showsCompactDetails = false
    @AppStorage("appearance") private var appearance = "system"
    @State private var insertError: String?
    @AppStorage("conversationSidebarWidth") private var savedSidebarWidth = 232.0
    @State private var changeReader = ChangeReaderWindow()
    private var sidebarMaximum: Double { min(360, max(200, windowSize.width - 400)) }
    private var sidebarWidth: CGFloat { min(sidebarMaximum, max(200, savedSidebarWidth)) }
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
                                .overlay(alignment: .trailing) { SidebarResizeHandle(width: $savedSidebarWidth, maximum: sidebarMaximum) }.zIndex(1)
                        }
                        ConversationView(session: session, brandIcon: Image(nsImage: PiBrand.icon),
                                         composerContext: ComposerContext(model: workspace.profile?.modelID ?? "Offline demo", policy: "Ask before tools",
                                             configure: { sheet = .connection }, addTextFile: insertTextFile,
                                             modelChoices: workspace.cwd == nil ? [] : workspace.profiles.map { profile in
                                                 ComposerContext.ModelChoice(id: profile.id, title: profile.modelID, detail: profile.name,
                                                     selected: profile.id == workspace.profile?.id, select: { Task { await workspace.selectConnection(profile) } })
                                             }), composerGeneration: workspace.composerGeneration, focusRequest: workspace.composerFocus,
                                         searchTerm: workspace.searchTerm, searchRequest: workspace.searchRequest, closeSearch: { workspace.searchTerm = "" }) { message in
                                                 MessageView(message: message, openChange: openChange)
                                             }
                            .frame(maxWidth: .infinity)
                        if showsDetails && detailsFit {
                            SessionDetails(workspace: workspace, session: session, expansion: detailsExpansion,
                                           openChange: openChange, close: { showsDetails = false })
                                .id(ObjectIdentifier(session)).frame(width: 288)
                        }
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
                    ToolbarItemGroup(placement: .primaryAction) {
                        detailsButton
                        windowActions.buttonStyle(.plain)
                    }
                }
                .toolbarBackground(headerBackground(width: geometry.size.width), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .chatTheme(ChatTheme(accent: PiBrand.accent, accentForeground: PiBrand.onAccent))
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .disabled(workspace.busy)
                .task { await workspace.start() }
                .onChange(of: geometry.size, initial: true) { windowSize = geometry.size }
                .onChange(of: detailsFit) { showsCompactDetails = false }
                .onChange(of: session?.sessionFile) { changeReader.close() }
                .onChange(of: session?.draft) { workspace.scheduleDraftSave() }
                .onChange(of: session?.isRunning) { if session?.isRunning == false { workspace.remember() } }
                .sheet(item: $sheet) { destination in
                    Group {
                        switch destination {
                        case .connection: ConnectionSheet(workspace: workspace)
                        case .rename:
                            ConversationTitleSheet(title: workspace.title) { try workspace.renameCurrent($0) }
                        }
                    }.chatTheme(ChatTheme(accent: PiBrand.accent, accentForeground: PiBrand.onAccent))
                }
                .alert("Couldn’t insert text", isPresented: Binding(get: { insertError != nil }, set: { if !$0 { insertError = nil } })) {
                    Button("OK") { insertError = nil }
                } message: { Text(insertError ?? "") }
        }
    }
    @ViewBuilder private var detailsButton: some View {
        if let session {
            Button {
                if detailsFit { showsDetails.toggle() } else { showsCompactDetails.toggle() }
            } label: {
                Image(systemName: "sidebar.right").font(.system(size: 18, weight: .regular))
                    .frame(width: 28, height: 32)
                    .background(.primary.opacity((detailsFit ? showsDetails : showsCompactDetails) ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("Session details · ⌥⌘I").accessibilityLabel("Session details")
                .accessibilityValue((detailsFit ? showsDetails : showsCompactDetails) ? "Shown" : "Hidden")
                .keyboardShortcut("i", modifiers: [.command, .option])
                .popover(isPresented: $showsCompactDetails, arrowEdge: .bottom) {
                    SessionDetails(workspace: workspace, session: session, expansion: detailsExpansion, compact: true,
                                   openChange: { showsCompactDetails = false; openChange($0) },
                                   close: { showsCompactDetails = false })
                        .id(ObjectIdentifier(session)).frame(width: 300, height: min(600, max(380, windowSize.height - 30)))
                        .chatTheme(ChatTheme(accent: PiBrand.accent, accentForeground: PiBrand.onAccent))
                }
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
    private func openChange(_ change: RecordedChange) {
        let changes = session?.displayedMessages.flatMap(\.tools).compactMap(RecordedChange.init) ?? []
        changeReader.present(changes: changes, selected: change.id, appearance: appearance)
    }
    private var windowIdentity: some View {
        HStack(spacing: 0) {
            Button { showsSidebar.toggle() } label: {
                ChatIcon(.sidebar, size: 18).frame(width: 28, height: 32)
            }.buttonStyle(.plain).help("Toggle sidebar").accessibilityLabel("Toggle sidebar")
                .keyboardShortcut("s", modifiers: [.command, .control])
                .frame(width: showsSidebar ? max(40, sidebarWidth - 96) : 40, alignment: .leading)
            Button { sheet = .rename } label: {
                Text(workspace.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Rename conversation · " + workspace.title)
                .accessibilityLabel("Rename conversation: " + workspace.title)
                .disabled(session?.workspace == nil || session?.isRunning == true)
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
                Button("Manage connections…", systemImage: ChatSymbol.settings.rawValue) { sheet = .connection }
                    .disabled(session.isRunning)
                if let file = session.sessionFile {
                    Button("Reveal saved session", systemImage: "doc.text") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                }
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

private enum AppSheet: Identifiable {
    case connection
    case rename
    var id: String {
        switch self { case .connection: "connection"; case .rename: "rename" }
    }
}

#else
@main struct PiSwiftApp { static func main() { print("PiSwift requires macOS.") } }
#endif
