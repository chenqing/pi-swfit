#if os(macOS)
import SwiftUI
import AppKit
import PiCodingAgent
import PiHost
import PiUI

/// A host-level navigator over the same on-disk conversations used by pf.
struct ConversationSidebar: View {
    let workspace: AppWorkspace
    let configure: () -> Void
    @State private var sessions: [SessionInfo] = []
    @State private var presentation: [String: ConversationPresentation] = [:]
    @State private var showsArchived = false
    @State private var renameTarget: RenameTarget?
    @State private var query = ""
    @State private var loading = false
    @State private var loadError: String?
    @State private var refresh = UUID()
    @FocusState private var searchFocused: Bool

    private var locked: Bool { workspace.busy || workspace.session?.isRunning == true }
    private var filtered: [SessionInfo] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { (presentation[$0.path]?.archived ?? false) == showsArchived && (term.isEmpty || title($0).localizedCaseInsensitiveContains(term)) }
            .sorted { a, b in
                let ap = presentation[a.path]?.pinned ?? false, bp = presentation[b.path]?.pinned ?? false
                return ap == bp ? a.modified > b.modified : ap
            }
    }
    private var refreshKey: String {
        "\(workspace.cwd ?? "")|\(workspace.session?.sessionFile ?? "")|\(workspace.session?.isRunning == true)|\(refresh)|\(workspace.libraryRevision)"
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

            HStack {
                Text(showsArchived ? "Archived" : workspace.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Conversations")
                    .lineLimit(1).truncationMode(.middle).help(workspace.cwd ?? "Conversations")
                Spacer()
                Menu {
                    Button(showsArchived ? "Show conversations" : "Show archived conversations") { showsArchived.toggle() }
                } label: { ChatIcon(.more, size: 13).frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Conversation list options")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.leading, 12).padding(.trailing, 4).padding(.top, 16).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if (workspace.session?.sessionFile == nil || (workspace.session?.messages.isEmpty == true && !sessions.contains { $0.path == workspace.session?.sessionFile })) && query.isEmpty && !showsArchived {
                        Text(workspace.profile == nil ? "Offline demo" : "New conversation")
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    }
                    ForEach(filtered, id: \.path) { info in
                        ConversationRow(title: title(info), pinned: presentation[info.path]?.pinned ?? false,
                            selected: info.path == workspace.session?.sessionFile, locked: locked,
                            open: { Task { await open(info) } }) {
                                Button("Rename…", systemImage: "pencil") { renameTarget = RenameTarget(info: info, title: title(info)) }
                                Button(presentation[info.path]?.pinned == true ? "Unpin" : "Pin", systemImage: "pin") {
                                    workspace.pin(info, pinned: !(presentation[info.path]?.pinned ?? false))
                                }
                                Divider()
                                Button(showsArchived ? "Restore conversation" : "Archive conversation", systemImage: "archivebox") {
                                    Task { await workspace.archive(info, archived: !showsArchived) }
                                }
                            }
                            .help("\(title(info))\n\(info.modified.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if loading && sessions.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
                    } else if filtered.isEmpty {
                        Text(query.isEmpty ? (showsArchived ? "No archived conversations" : workspace.cwd == nil ? "Connect a model and workspace to save conversations." : "Saved conversations appear here after a response.") : "No matching conversations")
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
            .sheet(item: $renameTarget) { target in
                ConversationTitleSheet(title: target.title) { try workspace.rename(target.info, title: $0) }
            }
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
            presentation = try workspace.library.load()
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
private struct RenameTarget: Identifiable {
    let info: SessionInfo
    let title: String
    var id: String { info.path }
}
private struct ConversationRow<Actions: View>: View {
    let title: String
    let pinned: Bool
    let selected: Bool
    let locked: Bool
    let open: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 6) {
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, 12).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            Menu(content: actions) { ChatIcon(.more, size: 13).frame(width: 26, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(hovered || selected ? 1 : 0.35).accessibilityLabel("Options for \(title)")
        }.padding(.trailing, 4).disabled(locked)
            .background(.primary.opacity(selected ? 0.065 : hovered ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }.contextMenu(menuItems: actions)
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
