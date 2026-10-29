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
    @State private var drafts: [ConversationDraftStore.Draft] = []
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
        return sessions.filter { (presentation[$0.path]?.archived ?? false) == showsArchived && (term.isEmpty || title($0).localizedCaseInsensitiveContains(term) || ConversationSearch.excerpt(in: $0.allMessagesText, matching: term) != nil) }
            .sorted { a, b in
                let ap = presentation[a.path]?.pinned ?? false, bp = presentation[b.path]?.pinned ?? false
                return ap == bp ? a.modified > b.modified : ap
            }
    }
    private var filteredDrafts: [ConversationDraftStore.Draft] {
        guard !showsArchived else { return [] }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return drafts.filter { $0.sessionFile != workspace.session?.sessionFile && (term.isEmpty || ConversationSearch.excerpt(in: $0.text, matching: term) != nil) }
    }
    private var refreshKey: String {
        "\(workspace.cwd ?? "")|\(workspace.session?.sessionFile ?? "")|\(workspace.session?.isRunning == true)|\(refresh)|\(workspace.libraryRevision)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { query = ""; Task { await workspace.newConversation() } } label: {
                HStack(spacing: 10) {
                    ChatIcon(.add, size: 13).frame(width: 18, height: 18)
                        .background(.primary.opacity(0.06), in: Circle())
                    Text("New conversation")
                    Spacer()
                    Text("⌘N").font(.system(size: 11)).foregroundStyle(ChatPalette.secondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                    .contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle()).disabled(locked)
                .padding(.top, 8)
            HStack(spacing: 8) {
                ChatIcon(.search).frame(width: 18).foregroundStyle(ChatPalette.secondaryText)
                TextField("Search conversations", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Search conversations").focused($searchFocused)
                    .onSubmit {
                        if let first = filtered.first, !locked { Task { await open(first) } }
                    }
                    .onExitCommand { query = ""; workspace.searchTerm = ""; searchFocused = false; workspace.composerFocus += 1 }
                if !query.isEmpty {
                    Button { query = ""; workspace.searchTerm = "" } label: { ChatIcon(.close, size: 10).frame(width: 20, height: 20) }
                        .buttonStyle(.plain).foregroundStyle(ChatPalette.secondaryText).accessibilityLabel("Clear search")
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
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(ChatPalette.secondaryText)
                .padding(.leading, 12).padding(.trailing, 4).padding(.top, 16).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if (workspace.session?.sessionFile == nil || (workspace.session?.messages.isEmpty == true && !sessions.contains { $0.path == workspace.session?.sessionFile })) && query.isEmpty && !showsArchived {
                        Text(workspace.profile == nil ? "Offline demo" : "New conversation")
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    }
                    ForEach(filteredDrafts) { draft in
                        Button {
                            Task {
                                do { try await workspace.resumeDraft(draft) }
                                catch { workspace.error = String(describing: error) }
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "square.and.pencil").font(.system(size: 11)).foregroundStyle(ChatPalette.secondaryText).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled draft" : draft.text)
                                        .lineLimit(1)
                                    Text(ConversationSearch.excerpt(in: draft.text, matching: query) ?? "Draft · Not sent")
                                        .font(.system(size: 11)).foregroundStyle(ChatPalette.secondaryText).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(SidebarButtonStyle()).disabled(locked)
                            .help("Unsent draft · \(draft.modified.formatted(date: .abbreviated, time: .shortened))")
                    }
                    ForEach(filtered, id: \.path) { info in
                        ConversationRow(title: title(info), snippet: ConversationSearch.excerpt(in: info.allMessagesText, matching: query), pinned: presentation[info.path]?.pinned ?? false,
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
                    } else if filtered.isEmpty && filteredDrafts.isEmpty {
                        Text(query.isEmpty ? (showsArchived ? "No archived conversations" : workspace.cwd == nil ? "Connect a model and workspace to save conversations." : "Conversations appear here after your first message.") : "No matching conversations")
                            .font(.system(size: 12)).foregroundStyle(ChatPalette.secondaryText).lineSpacing(3).padding(12)
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
                    ChatIcon(.settings).frame(width: 18).foregroundStyle(ChatPalette.secondaryText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.profile?.name ?? "Model & workspace").lineLimit(1)
                        Text(workspace.profile?.modelID ?? "Offline demo").font(.system(size: 11)).foregroundStyle(ChatPalette.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    ChatIcon(.down, size: 10).foregroundStyle(ChatPalette.secondaryText)
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle()).disabled(locked).help("Model & workspace")
                .accessibilityLabel("Model & workspace").padding(.bottom, 8)
        }.font(.system(size: 13)).padding(.horizontal, 8)
            .sheet(item: $renameTarget) { target in
                ConversationTitleSheet(title: target.title) { try workspace.rename(target.info, title: $0) }
            }
            .background(PiBrand.sidebar)
            .onChange(of: workspace.searchFocus, initial: true) {
                if workspace.searchFocus > 0 {
                    // The menu can insert a previously hidden sidebar. Wait until
                    // its native text field has joined the window's focus chain.
                    DispatchQueue.main.async { searchFocused = true }
                }
            }
            .onChange(of: workspace.newConversationRequest) { query = "" }
            .task(id: refreshKey) { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh = UUID() }
    }
    private func title(_ info: SessionInfo) -> String {
        info.name ?? (info.firstMessage.isEmpty ? "Untitled conversation" : info.firstMessage)
    }
    private func reload() async {
        loadError = nil
        guard let cwd = workspace.cwd else { sessions = []; drafts = []; loading = false; return }
        loading = true
        do {
            let result = try await SessionManager.list(cwd, workspace.store.paths.sessionDirectory(cwd: cwd))
            guard !Task.isCancelled else { return }
            // A damaged draft must not hide otherwise readable transcripts.
            do { drafts = try workspace.unsentDrafts() }
            catch { drafts = []; loadError = "Couldn’t load drafts. \(error)" }
            presentation = try workspace.library.load()
            sessions = result.sorted { $0.modified > $1.modified }
        } catch {
            guard !Task.isCancelled else { return }
            sessions = []; loadError = "Couldn’t load conversations. \(error)"
        }
        loading = false
    }
    private func open(_ info: SessionInfo) async {
        do {
            try await workspace.resume(info)
            workspace.searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
            workspace.searchRequest = UUID()
        }
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
    let snippet: String?
    let pinned: Bool
    let selected: Bool
    let locked: Bool
    let open: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var hovered = false
    @FocusState private var rowFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 6) {
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(ChatPalette.secondaryText) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).lineLimit(1)
                        if let snippet { Text(snippet).font(.system(size: 11)).foregroundStyle(ChatPalette.secondaryText).lineLimit(2) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, 12).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).focused($rowFocused)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(rowFocused ? PiBrand.accent : .clear, lineWidth: 2))
                .accessibilityAddTraits(selected ? .isSelected : [])
            Menu(content: actions) { ChatIcon(.more, size: 13).frame(width: 26, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(hovered || selected ? 1 : 0.75).accessibilityLabel("Options for \(title)")
        }.padding(.trailing, 4).disabled(locked)
            .background(.primary.opacity(selected ? 0.065 : hovered ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }.contextMenu(menuItems: actions)
    }
}
private struct SidebarButtonStyle: ButtonStyle {
    var selected = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.10 : selected ? 0.065 : hovered && enabled ? 0.035 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? PiBrand.accent : .clear, lineWidth: 2))
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}
#endif
