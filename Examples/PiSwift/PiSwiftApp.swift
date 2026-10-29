import SwiftUI
import PiUI
import PiChat
import PiAI
import PiAgent
import PiHost
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
            .commands { ConversationCommands() }
        Settings { AppSettings(workspace: workspace) }
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
    @Environment(\.openSettings) private var openSettings
    @AppStorage("conversationTextSize") private var textSize = 15.0
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
                if let session {
                    HStack(spacing: 0) {
                        if showsSidebar {
                            ConversationSidebar(workspace: workspace, configure: { sheet = .connection })
                                .frame(width: sidebarWidth)
                                .overlay(alignment: .trailing) { SidebarResizeHandle(width: $savedSidebarWidth, maximum: sidebarMaximum) }.zIndex(1)
                        }
                        ConversationView(session: session, brandIcon: Image(nsImage: PiBrand.icon),
                                         composerContext: ComposerContext(model: workspace.profile?.modelID ?? "Offline demo", policy: session.permissionMode.title,
                                             configure: { sheet = .connection }, addTextFile: insertTextFile,
                                             modelChoices: workspace.cwd == nil ? [] : workspace.profiles.map { profile in
                                                 ComposerContext.ModelChoice(id: profile.id, title: profile.modelID, detail: profile.name,
                                                     selected: profile.id == workspace.profile?.id, select: { Task { await workspace.selectConnection(profile) } })
                                             }, permissionMode: session.permissionMode, canSelectPermissionMode: session.canSelectPermissionMode,
                                             selectPermissionMode: { mode in
                                                 do { try session.selectPermissionMode(mode) }
                                                 catch { workspace.error = String(describing: error) }
                                             }, submitCommand: handleCommand, commandNotice: workspace.commandNotice, commandError: workspace.error, commandWorking: workspace.commandWorking, dismissNotice: { workspace.commandNotice = nil; workspace.error = nil }, commands: session.commands), composerGeneration: workspace.composerGeneration, focusRequest: workspace.composerFocus,
                                         searchTerm: workspace.searchTerm, searchRequest: workspace.searchRequest, closeSearch: { workspace.searchTerm = "" },
                                         trailingAccessoryWidth: showsDetails && detailsFit ? 302 : 0) { message in
                                                 MessageView(message: message, openChange: openChange)
                                             }
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .trailing) {
                                if showsDetails && detailsFit {
                                    SessionDetails(workspace: workspace, session: session, expansion: detailsExpansion,
                                                   openChange: openChange, close: { showsDetails = false })
                                        .id(ObjectIdentifier(session)).frame(width: 288).padding(.trailing, 14)
                                }
                            }
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.background { windowBackground.ignoresSafeArea(.container, edges: .top) }
                .overlay(alignment: .top) {
                    // Paint the titlebar in the content coordinate space, using the same
                    // exact sidebar edge. Native toolbar materials blur gradient stops.
                    windowBackground.frame(height: geometry.safeAreaInsets.top)
                        .offset(y: -geometry.safeAreaInsets.top).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .toolbar {
                    // Separate native items keep title sizing and AX labels stable
                    // while the sidebar item's reserved width changes.
                    ToolbarItem(placement: .navigation) { sidebarControl.id(showsSidebar) }
                    ToolbarItem(placement: .navigation) { conversationTitle }
                    ToolbarItem(placement: .principal) { Spacer(minLength: 0) }
                    ToolbarItemGroup(placement: .primaryAction) {
                        detailsButton
                        windowActions.buttonStyle(.plain)
                    }
                }
                .toolbarBackground(.hidden, for: .windowToolbar)
                .chatTheme(ChatTheme(accent: PiBrand.accent, accentForeground: PiBrand.onAccent, textSize: textSize))
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .disabled(workspace.busy)
                .focusedSceneValue(\.conversationMenu, sheet == nil && !workspace.busy ? ConversationMenuActions(
                    newConversation: { Task { await workspace.newConversation() } },
                    canCreateConversation: session != nil && session?.isRunning != true,
                    find: { showsSidebar = true; workspace.searchFocus += 1 },
                    focusComposer: { workspace.composerFocus += 1 },
                    toggleSidebar: { showsSidebar.toggle() }, toggleDetails: toggleDetails,
                    help: { sheet = .command(.information(CommandDescriptor.help(session?.commands ?? CommandDescriptor.builtins())), "") },
                    showsSidebar: showsSidebar, showsDetails: detailsFit ? showsDetails : showsCompactDetails) : nil)
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
                        case .command(let kind, let input):
                            SlashCommandSheet(workspace: workspace, kind: kind, input: input)
                        case .rename:
                            ConversationTitleSheet(title: workspace.title) { try workspace.renameCurrent($0) }
                        }
                    }.chatTheme(ChatTheme(accent: PiBrand.accent, accentForeground: PiBrand.onAccent, textSize: textSize))
                }
                .alert("Couldn’t insert text", isPresented: Binding(get: { insertError != nil }, set: { if !$0 { insertError = nil } })) {
                    Button("OK") { insertError = nil }
                } message: { Text(insertError ?? "") }
        }
    }
    @ViewBuilder private var detailsButton: some View {
        if let session {
            Button(action: toggleDetails) {
                Image(systemName: "sidebar.right").font(.system(size: 18, weight: .regular))
                    .frame(width: 28, height: 32)
                    .background(.primary.opacity((detailsFit ? showsDetails : showsCompactDetails) ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("Session details · ⌥⌘I").accessibilityLabel("Session details")
                .accessibilityValue((detailsFit ? showsDetails : showsCompactDetails) ? "Shown" : "Hidden")
                .popover(isPresented: $showsCompactDetails, arrowEdge: .bottom) {
                    SessionDetails(workspace: workspace, session: session, expansion: detailsExpansion, compact: true,
                                   openChange: { showsCompactDetails = false; openChange($0) },
                                   close: { showsCompactDetails = false })
                        .id(ObjectIdentifier(session)).frame(width: 300, height: min(600, max(380, windowSize.height - 30)))
                        .chatTheme(ChatTheme(accent: PiBrand.accent, accentForeground: PiBrand.onAccent, textSize: textSize))
                }
        }
    }
    private func toggleDetails() {
        if detailsFit { showsDetails.toggle() } else { showsCompactDetails.toggle() }
    }
    private var windowBackground: some View {
        HStack(spacing: 0) {
            if showsSidebar { PiBrand.sidebar.frame(width: sidebarWidth) }
            PiBrand.canvas
        }
    }
    private func openChange(_ change: RecordedChange) {
        let changes = session?.displayedMessages.flatMap(\.tools).compactMap(RecordedChange.init) ?? []
        changeReader.present(changes: changes, selected: change.id, appearance: appearance)
    }
    private var sidebarControl: some View {
        Button { showsSidebar.toggle() } label: {
            ChatIcon(.sidebar, size: 18).frame(width: 28, height: 32)
        }.buttonStyle(.plain).help("Toggle sidebar").accessibilityLabel("Toggle sidebar")
            .accessibilityIdentifier("conversation-sidebar-toggle")
            .frame(width: showsSidebar ? max(40, sidebarWidth - 96) : 40, alignment: .leading)
            .frame(height: 36).padding(.leading, 8)
    }
    private var conversationTitle: some View {
        Button { sheet = .rename } label: {
            Text(workspace.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Rename conversation · " + workspace.title)
            .accessibilityLabel("Rename conversation: " + workspace.title)
            .accessibilityIdentifier("conversation-title")
            .padding(.leading, showsSidebar ? 24 : 0).frame(height: 36)
            .disabled(session?.workspace == nil || session?.isRunning == true)
    }
    private func handleCommand(_ input: String) {
        guard let target = session, !target.isRunning, !workspace.busy else { return }
        Task { @MainActor in
            workspace.beginCommand(); target.clearCommandError()
            do {
                guard let invocation = try SlashCommand.parse(input, catalog: target.commands) else { await target.send(); return }
                let argument = invocation.argument
                switch invocation.command {
                case .thinking where argument.isEmpty: sheet = .command(.thinking, input)
                case .tree: sheet = .command(.tree, input)
                case .fork: sheet = .command(.fork, input)
                case .resume:
                    guard target.workspace != nil else { throw PiError("Open a workspace before resuming conversations") }
                    sheet = .command(.resume, input)
                case .model where argument.isEmpty: sheet = .command(.model, input)
                case .name where argument.isEmpty: sheet = .command(.name, input)
                case .quit: throw PiError("Use Command-Q to quit Pi Swift")
                default:
                    try await target.consumeCommand(input) {
                        switch invocation.command {
                        case .thinking:
                            try await target.selectThinking(argument)
                            workspace.commandNotice = "Thinking: " + argument.lowercased()
                        case .new: try await workspace.startNewConversation()
                        case .name: try workspace.renameCurrent(argument); workspace.commandNotice = "Conversation renamed"
                        case .model:
                            try workspace.refreshProfiles()
                            let selected = try SlashCommand.matchConnection(argument, profiles: workspace.profiles)
                            try await workspace.selectCommandConnection(selected)
                        case .reload:
                            let warnings = try await target.reloadResources()
                            workspace.commandNotice = warnings.isEmpty ? "Skills, templates and native extension resources reloaded" : "Reloaded with warnings"
                            if !warnings.isEmpty { sheet = .command(.information(warnings.joined(separator: "\n\n")), "") }
                        case .settings: openSettings()
                        case .compact:
                            workspace.commandWorking = true
                            defer { workspace.commandWorking = false }
                            workspace.commandNotice = "Compacting context…"
                            do {
                                workspace.commandNotice = try await target.compact(argument)
                                workspace.remember()
                            } catch {
                                workspace.commandNotice = nil
                                throw error
                            }
                        case .session: sheet = .command(.information(try await target.sessionInformation()), "")
                        case .copy:
                            guard let text = target.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text else { workspace.commandNotice = CommandFeedback.nothingToCopy; return }
                            NSPasteboard.general.clearContents()
                            guard NSPasteboard.general.setString(text, forType: .string) else { throw PiError("Could not copy the response") }
                            workspace.commandNotice = "Copied last response"
                        case .help:
                            sheet = .command(.information(CommandDescriptor.help(target.commands)), "")
                        default: break
                        }
                    }
                    workspace.composerFocus += 1
                }
            } catch { workspace.commandFailed(error) }
        }
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
    case command(CommandSheetKind, String)
    var id: String {
        switch self { case .connection: "connection"; case .rename: "rename"; case .command: "command" }
    }
}

#else
@main struct PiSwiftApp { static func main() { print("PiSwift requires macOS.") } }
#endif
