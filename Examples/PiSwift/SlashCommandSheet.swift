import SwiftUI
import PiAI
import PiChat
import PiHost
import PiCodingAgent

enum CommandSheetKind {
    case model, resume, name, thinking, tree, fork, information(String)
    var title: String {
        switch self { case .thinking: "Thinking level"; case .tree: "Conversation tree"; case .fork: "Fork conversation"; case .model: "Choose model"; case .resume: "Resume conversation"; case .name: "Rename conversation"; case .information: "Session commands" }
    }
}

struct SlashCommandSheet: View {
    @Bindable var workspace: AppWorkspace
    let kind: CommandSheetKind
    let input: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sessions: [SessionInfo] = []
    @State private var levels: [ModelThinkingLevel] = []
    @State private var currentLevel: ModelThinkingLevel = .off
    @State private var entries: [SessionNavigationItem] = []
    @State private var selectedID: String?
    @State private var summarize = false
    @State private var instructions = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind.title).font(.headline)
            Group {
            switch kind {
            case .information(let text):
                ScrollView { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260)
            case .thinking:
                Text("Applies to this conversation. Available levels depend on the model.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(levels, id: \.self) { level in
                            Button {
                                run {
                                    try await workspace.session?.selectThinking(level.rawValue)
                                    workspace.commandNotice = "Thinking: " + level.rawValue
                                }
                            } label: {
                                HStack {
                                    Text(level.rawValue)
                                    Spacer()
                                    if level == currentLevel { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                                    .background(level == currentLevel ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityLabel(level.rawValue + (level == currentLevel ? ", Current" : ""))
                        }
                    }
                }.frame(height: CGFloat(min(levels.count, 7)) * 38)
                if levels == [.off] {
                    Text("This connection has no thinking capability configured. For a custom model, set its supported levels in /settings.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .tree, .fork:
                navigationContent
            case .name:
                TextField("Conversation title", text: $query).textFieldStyle(.roundedBorder).focused($focused)
            case .model, .resume:
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if case .model = kind {
                            if workspace.profiles.isEmpty { Text("No saved connections. Use /settings to add one.").foregroundStyle(.secondary) }
                            ForEach(workspace.profiles.filter { query.isEmpty || ($0.name + " " + $0.modelID).localizedCaseInsensitiveContains(query) }) { profile in
                                choice(profile.modelID, detail: profile.name) { try await workspace.selectCommandConnection(profile) }
                            }
                        } else {
                            if sessions.isEmpty { Text("No saved conversations in this workspace.").foregroundStyle(.secondary) }
                            ForEach(sessions.filter { query.isEmpty || ($0.name ?? $0.firstMessage).localizedCaseInsensitiveContains(query) }, id: \.path) { item in
                                choice(item.name ?? item.firstMessage, detail: item.modified.formatted(date: .abbreviated, time: .shortened)) { try await workspace.resume(item) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 240)
            }
            }.disabled(working)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(working ? "Cancel operation" : "Close") {
                    if working { workspace.session?.stop() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(working && !summarize)
                if isNavigation {
                    Button(isFork ? "Create fork" : "Go to selected point") {
                        guard let selectedID else { return }
                        run { try await workspace.navigate(to: selectedID, fork: isFork, summarize: summarize, instructions: instructions) }
                    }.keyboardShortcut(.defaultAction).disabled(working || !filteredEntries.contains { $0.id == selectedID })
                }
                if case .name = kind {
                    Button("Save") { run { try workspace.renameCurrent(query) } }
                        .keyboardShortcut(.defaultAction).disabled(working || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(24).frame(width: 420).interactiveDismissDisabled(working)
            .task {
                focused = true
                do {
                    if case .thinking = kind, let session = workspace.session {
                        let options = try await session.thinkingOptions()
                        levels = options.levels; currentLevel = options.current
                    }
                    if isNavigation {
                        entries = try workspace.session?.navigationItems(forkOnly: isFork) ?? []
                        selectedID = isFork ? entries.last?.id : entries.first(where: \.isCurrent)?.id
                    }
                    if case .model = kind { try workspace.refreshProfiles() }
                    if case .name = kind { query = workspace.title }
                    if case .resume = kind, let cwd = workspace.cwd {
                        sessions = try await SessionManager.list(cwd, workspace.store.paths.sessionDirectory(cwd: cwd))
                    }
                } catch { self.error = String(describing: error) }
            }
    }
    private var isFork: Bool { if case .fork = kind { true } else { false } }
    private var isNavigation: Bool { if case .tree = kind { true } else { isFork } }
    private var filteredEntries: [SessionNavigationItem] {
        entries.filter { query.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query) }
    }
    private var navigationContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isFork ? "Create a separate conversation before a user message. Its text returns to the composer for editing."
                 : "Stay in this conversation. Selecting a user message restores it for editing; other entries continue from that point.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search history", text: $query).textFieldStyle(.roundedBorder).focused($focused)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if filteredEntries.isEmpty { Text("No matching history.").foregroundStyle(.secondary).padding(12) }
                        ForEach(filteredEntries) { item in
                            Button { selectedID = item.id } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.isCurrent ? "location.fill" : item.isUser ? "person" : "point.topleft.down.to.point.bottomright.curvepath")
                                        .frame(width: 16).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title.isEmpty ? "Empty message" : item.title).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(item.detail + (item.isCurrent ? " · Current" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if item.id == selectedID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }.padding(10).padding(.leading, CGFloat(min(item.depth, 6)) * 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(item.id == selectedID ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(item.id)
                                .accessibilityLabel(item.title + (item.isCurrent ? ", Current" : ""))
                        }
                    }
                }.frame(height: 210)
                    .onChange(of: entries.count) { if let selectedID { proxy.scrollTo(selectedID, anchor: .center) } }
            }
            if !isFork {
                Toggle("Summarize the branch being left", isOn: $summarize)
                if summarize {
                    TextField("Summary instructions (optional)", text: $instructions).textFieldStyle(.roundedBorder)
                    Text("Uses the current model. History moves only after the summary succeeds.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func choice(_ title: String, detail: String, action: @escaping () async throws -> Void) -> some View {
        Button { run(action) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? "Untitled conversation" : title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
        }.buttonStyle(.borderless)
    }
    private func run(_ action: @escaping () async throws -> Void) {
        guard !working, let session = workspace.session else { return }
        working = true; error = nil
        Task { @MainActor in
            defer { working = false }
            do {
                try await session.consumeCommand(input, action: action)
                workspace.composerFocus += 1
                dismiss()
            } catch { self.error = String(describing: error) }
        }
    }
}
