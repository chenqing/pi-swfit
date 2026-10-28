import Foundation
import Observation
import PiAI
import PiChat
import PiHost
import PiCodingAgent

@MainActor @Observable
final class AppWorkspace {
    var session: ChatSession?
    var profile: ConnectionProfile?
    var error: String?
    var busy = false
    var connection = "Offline demo"
    let store = ConnectionStore()
    var cwd: String? { session?.workspace }

    func insertTextFile(_ url: URL) async throws {
        guard let target = session else { return }
        let content = try await Task.detached {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 128 * 1024 + 1) ?? Data()
            guard data.count <= 128 * 1024 else { throw PiError("Choose a text file smaller than 128 KB.") }
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                throw PiError("This file is not UTF-8 text. Choose a source file or plain text document.")
            }
            return text
        }.value
        guard session === target else { throw PiError("The conversation changed. Insert the file again in the new conversation.") }
        guard !content.isEmpty else { return }
        target.draft += (target.draft.isEmpty ? "" : "\n\n") + content
    }

    func start() async {
        guard session == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            if let bookmark = try WorkspaceBookmark.load(paths: store.paths),
               let profile = try store.load().profile(bookmark.connectionID) {
                let file = bookmark.sessionFile.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                let restored = try await ChatSession.openCoding(cwd: bookmark.cwd, profile: profile, store: store, sessionFile: file)
                await replace(restored, profile: profile)
            } else { await demo(.tool) }
        } catch {
            await demo(.tool, clearError: false)
            self.error = "Could not restore the last workspace: \(error)"
        }
    }
    func connect(profile: ConnectionProfile, key: String?, cwd: String) async throws {
        guard session?.isRunning != true, !busy else { throw PiError("Wait for the current operation to finish") }
        busy = true; defer { busy = false }
        let store = self.store
        try await Task.detached { try store.save(profile, apiKey: key) }.value
        let next = try await ChatSession.openCoding(cwd: cwd, profile: profile, store: store)
        await replace(next, profile: profile)
        remember()
    }
    func resume(_ info: SessionInfo) async throws {
        guard session?.isRunning != true, !busy else { throw PiError("Wait for the current operation to finish") }
        if session?.sessionFile == info.path { return }
        busy = true; defer { busy = false }
        let manager = try SessionManager.open(info.path)
        guard let id = CodingSessionHost.savedConnectionID(manager) else { throw PiError("This session has no saved connection. Open it with pf --connection NAME --session PATH first.") }
        guard let selected = try store.load().profile(id) else { throw PiError("Connect a model before opening this session") }
        let next = try await ChatSession.openCoding(cwd: info.cwd, profile: selected, store: store, sessionFile: info.path)
        await replace(next, profile: selected)
        remember()
    }
    func newConversation() async {
        guard !busy, session?.isRunning != true else { return }
        busy = true; defer { busy = false }
        do { try await session?.reset(); remember() }
        catch { self.error = String(describing: error) }
    }
    func demo(_ scenario: DemoScenario, clearError: Bool = true) async {
        guard session?.isRunning != true else { return }
        do {
            let next = try makeDemoSession(scenario: scenario)
            await replace(next, profile: nil)
            connection = "Offline demo · \(scenario.rawValue)"
            if clearError { error = nil }
        } catch { self.error = String(describing: error) }
    }
    func remember() {
        guard let session, let cwd = session.workspace, let id = session.connectionID else { return }
        do { try WorkspaceBookmark(cwd: cwd, connectionID: id, sessionFile: session.sessionFile).save(paths: store.paths) }
        catch { self.error = "Could not save the last workspace: \(error)" }
    }
    func shutdown() async { remember(); await session?.shutdown() }
    private func replace(_ next: ChatSession, profile: ConnectionProfile?) async {
        let old = session
        session = next; self.profile = profile; connection = profile?.name ?? "Offline demo"; error = nil
        await old?.shutdown()
    }
}
