import SwiftUI
import PiUI
import PiChat
import PiAI
import PiAgent
#if os(macOS)
import AppKit

private let playgroundAccent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.64, green: 0.81, blue: 0.71, alpha: 1)
        : NSColor(red: 0.24, green: 0.42, blue: 0.35, alpha: 1)
})
private let playgroundOnAccent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
})

@main
struct PiPlaygroundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var workspace = PlaygroundWorkspace()
    var body: some Scene {
        Window("Pi Playground", id: "main") { Playground(workspace: workspace).frame(minWidth: 640, minHeight: 560).onAppear { delegate.workspace = workspace } }
            .defaultSize(width: 860, height: 760).windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unified)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: PlaygroundWorkspace?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await workspace?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct Playground: View {
    @Bindable var workspace: PlaygroundWorkspace
    private var session: ChatSession? { workspace.session }
    private var connection: String { workspace.connection }
    @State private var sheet: PlaygroundSheet?
    @State private var compact = false
    @State private var appearance = "system"
    var body: some View {
        VStack(spacing: 0) {
            if let error = workspace.error {
                HStack { Text(error).font(.callout).foregroundStyle(.red); Spacer(); Button("Dismiss") { workspace.error = nil } }.padding(12)
            }
            if let session {
                HStack(spacing: 0) {
                    if compact { contextExample.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    ConversationView(session: session).frame(maxWidth: compact ? 440 : .infinity)
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(Color(nsColor: .textBackgroundColor))
            .toolbar {
                ToolbarItem(placement: .navigation) { windowIdentity }
                ToolbarItem(placement: .principal) { Spacer(minLength: 0) }
                ToolbarItemGroup(placement: .primaryAction) { windowActions.buttonStyle(.plain) }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .chatTheme(ChatTheme(accent: playgroundAccent, accentForeground: playgroundOnAccent))
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .disabled(workspace.busy)
            .task { await workspace.start() }
            .onChange(of: session?.isRunning) { if session?.isRunning == false { workspace.remember() } }
            .sheet(item: $sheet) { destination in
                Group {
                    switch destination {
                    case .connection: ConnectionSheet(workspace: workspace)
                    case .sessions: SessionsSheet(workspace: workspace)
                    }
                }.chatTheme(ChatTheme(accent: playgroundAccent, accentForeground: playgroundOnAccent))
            }
    }
    private var windowIdentity: some View {
        HStack(spacing: 9) {
            Text("π").font(.system(size: 22, weight: .medium, design: .serif)).foregroundStyle(playgroundAccent)
            Text("Pi Playground").font(.system(size: 13, weight: .medium))
        }.frame(height: 36).padding(.leading, 8).help(connection)
    }
    @ViewBuilder private var windowActions: some View {
        if let session {
            Button { Task { await workspace.newConversation() } } label: {
                Image(systemName: "square.and.pencil").frame(width: 24, height: 32)
            }.help("New conversation").accessibilityLabel("New conversation").disabled(session.isRunning)
            Button { compact.toggle() } label: {
                Image(systemName: "sidebar.right").frame(width: 24, height: 32)
            }.help("Toggle compact layout").accessibilityLabel("Toggle compact layout")
            Menu {
                Text(connection)
                if let cwd = workspace.cwd { Text(URL(fileURLWithPath: cwd).lastPathComponent) }
                Button("Resume conversation…", systemImage: "clock.arrow.circlepath") { sheet = .sessions }
                    .disabled(session.isRunning || workspace.cwd == nil)
                Button("Model & workspace…", systemImage: "slider.horizontal.3") { sheet = .connection }
                    .disabled(session.isRunning)
                Divider()
                Menu("Scenarios") {
                    ForEach(DemoScenario.allCases, id: \.self) { scenario in
                        Button(scenario.rawValue == "tool" ? "Tool approval" : scenario.rawValue == "failure" ? "Connection failure" : "Long streaming reply") {
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
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 32) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More options").accessibilityLabel("More options")
        }
    }
    private var contextExample: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("YOUR WORKSPACE", systemImage: "square.dashed").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.tertiary)
            Text("A quiet companion\nfor your work.").font(.system(size: 27, weight: .medium, design: .serif)).lineSpacing(4)
            Text("The same conversation fits beside a document, an editor, or your next idea.")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
            Rectangle().fill(.primary.opacity(0.06)).frame(height: 1)
            Text("ConversationView(session: session)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Label("One session. Any layout.", systemImage: "rectangle.3.group")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }.padding(30).padding(.top, 45).background(.primary.opacity(0.025))
    }
}

private enum PlaygroundSheet: String, Identifiable {
    case connection, sessions
    var id: String { rawValue }
}

#else
@main struct PiPlaygroundApp { static func main() { print("PiPlayground requires macOS.") } }
#endif
