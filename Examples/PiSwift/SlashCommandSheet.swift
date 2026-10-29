import SwiftUI
import PiChat
import PiHost
import PiCodingAgent

enum CommandSheetKind {
    case model, resume, name, information(String)
    var title: String {
        switch self { case .model: "Choose model"; case .resume: "Resume conversation"; case .name: "Rename conversation"; case .information: "Session commands" }
    }
}

struct SlashCommandSheet: View {
    @Bindable var workspace: AppWorkspace
    let kind: CommandSheetKind
    let input: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sessions: [SessionInfo] = []
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind.title).font(.headline)
            switch kind {
            case .information(let text):
                ScrollView { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260)
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
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if case .name = kind {
                    Button("Save") { run { try workspace.renameCurrent(query) } }
                        .keyboardShortcut(.defaultAction).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(24).frame(width: 420).disabled(working).interactiveDismissDisabled(working)
            .task {
                focused = true
                do {
                    if case .model = kind { try workspace.refreshProfiles() }
                    if case .name = kind { query = workspace.title }
                    if case .resume = kind, let cwd = workspace.cwd {
                        sessions = try await SessionManager.list(cwd, workspace.store.paths.sessionDirectory(cwd: cwd))
                    }
                } catch { self.error = String(describing: error) }
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
