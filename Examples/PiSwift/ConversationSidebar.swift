#if os(macOS)
import SwiftUI
import AppKit
import PiCodingAgent
import PiUI

/// A host-level navigator over the same on-disk conversations used by pf.
struct ConversationSidebar: View {
    let workspace: AppWorkspace
    let configure: () -> Void
    @State private var sessions: [SessionInfo] = []
    @State private var query = ""
    @State private var loading = false
    @State private var loadError: String?
    @State private var refresh = UUID()
    @FocusState private var searchFocused: Bool

    private var locked: Bool { workspace.busy || workspace.session?.isRunning == true }
    private var filtered: [SessionInfo] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { term.isEmpty || title($0).localizedCaseInsensitiveContains(term) }
    }
    private var refreshKey: String {
        "\(workspace.cwd ?? "")|\(workspace.session?.sessionFile ?? "")|\(workspace.session?.isRunning == true)|\(refresh)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { Task { await workspace.newConversation() } } label: {
                HStack(spacing: 10) {
                    ChatIcon(.add, size: 13).frame(width: 18, height: 18)
                        .background(.primary.opacity(0.06), in: Circle())
                    Text("New conversation")
                    Spacer()
                    Text("⌘N").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                    .contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle()).disabled(locked).keyboardShortcut("n", modifiers: .command)
                .padding(.top, 8)
            HStack(spacing: 8) {
                ChatIcon(.search).frame(width: 18).foregroundStyle(.secondary)
                TextField("Search conversations", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Search conversations").focused($searchFocused)
                    .onExitCommand { query = ""; searchFocused = false }
                if !query.isEmpty {
                    Button { query = "" } label: { ChatIcon(.close, size: 10).frame(width: 20, height: 20) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
                .background(.primary.opacity(searchFocused ? 0.045 : 0.025), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(PiBrand.accent.opacity(searchFocused ? 0.30 : 0), lineWidth: 1) }
                .padding(.horizontal, 2).padding(.top, 4)

            Text(workspace.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Conversations")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(workspace.cwd ?? "Conversations").padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if (workspace.session?.sessionFile == nil || (workspace.session?.messages.isEmpty == true && !sessions.contains { $0.path == workspace.session?.sessionFile })) && query.isEmpty {
                        Text(workspace.profile == nil ? "Offline demo" : "New conversation")
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    }
                    ForEach(filtered, id: \.path) { info in
                        Button { Task { await open(info) } } label: {
                            Text(title(info)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }.buttonStyle(SidebarButtonStyle(selected: info.path == workspace.session?.sessionFile)).disabled(locked)
                            .help("\(title(info))\n\(info.modified.formatted(date: .abbreviated, time: .shortened))")
                            .accessibilityAddTraits(info.path == workspace.session?.sessionFile ? .isSelected : [])
                    }
                    if loading && sessions.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
                    } else if filtered.isEmpty {
                        Text(query.isEmpty ? (workspace.cwd == nil ? "Connect a model and workspace to save conversations." : "Saved conversations appear here after a response.") : "No matching conversations")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).padding(12)
                    }
                    if let loadError {
                        Text(loadError).font(.caption).foregroundStyle(.red).padding(12)
                        Button("Retry") { refresh = UUID() }.padding(.horizontal, 12)
                    }
                }
            }
            Spacer(minLength: 12)
            Button(action: configure) {
                HStack(spacing: 10) {
                    ChatIcon(.settings).frame(width: 18).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.profile?.name ?? "Model & workspace").lineLimit(1)
                        Text(workspace.profile?.modelID ?? "Offline demo").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    ChatIcon(.down, size: 10).foregroundStyle(.tertiary)
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle()).disabled(locked).help("Model & workspace")
                .accessibilityLabel("Model & workspace").padding(.bottom, 8)
        }.font(.system(size: 13)).padding(.horizontal, 8)
            .background(PiBrand.sidebar)
            .task(id: refreshKey) { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh = UUID() }
    }
    private func title(_ info: SessionInfo) -> String {
        info.name ?? (info.firstMessage.isEmpty ? "Untitled conversation" : info.firstMessage)
    }
    private func reload() async {
        loadError = nil
        guard let cwd = workspace.cwd else { sessions = []; loading = false; return }
        loading = true
        do {
            let result = try await SessionManager.list(cwd, workspace.store.paths.sessionDirectory(cwd: cwd))
            guard !Task.isCancelled else { return }
            sessions = result.sorted { $0.modified > $1.modified }
        } catch {
            guard !Task.isCancelled else { return }
            sessions = []; loadError = "Couldn’t load conversations. \(error)"
        }
        loading = false
    }
    private func open(_ info: SessionInfo) async {
        do { try await workspace.resume(info) }
        catch { workspace.error = String(describing: error) }
    }
}
private struct SidebarButtonStyle: ButtonStyle {
    var selected = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.10 : selected ? 0.065 : hovered && enabled ? 0.035 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}
#endif
