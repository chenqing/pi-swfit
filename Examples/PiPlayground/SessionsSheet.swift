#if os(macOS)
import SwiftUI
import PiCodingAgent
import PiUI

struct SessionsSheet: View {
    let workspace: PlaygroundWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionInfo] = []
    @State private var loading = true
    @State private var error: String?
    @State private var opening = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resume conversation").font(.title2.weight(.semibold))
            if let cwd = workspace.cwd { Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 160) }
            else if sessions.isEmpty { Text("Your saved conversations will appear here after a response.").foregroundStyle(.secondary).frame(minHeight: 160) }
            else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sessions, id: \.path) { info in
                            Button { Task { await open(info) } } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(info.name ?? (info.firstMessage.isEmpty ? "Untitled conversation" : info.firstMessage))
                                            .font(.system(size: 14, weight: .medium)).lineLimit(2)
                                        Text(info.modified, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if info.path == workspace.session?.sessionFile { Text("Current").font(.caption).foregroundStyle(.secondary) }
                                    else { Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary) }
                                }.padding(12).contentShape(Rectangle()).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 300)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(ChatButtonStyle()).keyboardShortcut(.cancelAction) }
        }.padding(28).frame(width: 460).disabled(opening).interactiveDismissDisabled(opening)
            .task {
                defer { loading = false }
                guard let cwd = workspace.cwd else { return }
                do { sessions = try await SessionManager.list(cwd, workspace.store.paths.sessionDirectory(cwd: cwd)) }
                catch { self.error = String(describing: error) }
            }
    }
    private func open(_ info: SessionInfo) async {
        opening = true; defer { opening = false }
        do { try await workspace.resume(info); dismiss() }
        catch { self.error = String(describing: error) }
    }
}
#endif
