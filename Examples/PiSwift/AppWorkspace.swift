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
    var commandNotice: String?
    var busy = false
    var connection = "Offline demo"
    let store = ConnectionStore()
    var profiles: [ConnectionProfile] = []
    var libraryRevision = 0
    var composerGeneration = 0
    var newConversationRequest = 0
    var composerFocus = 0
    var searchTerm = ""
    var searchRequest = UUID()
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    private var drafts: ConversationDraftStore { ConversationDraftStore(paths: store.paths) }
    private func saveDraft() throws {
        draftSaveTask?.cancel(); draftSaveTask = nil
        if let session, let file = session.sessionFile { try drafts.save(session.draft, for: file, connectionID: session.connectionID, position: session.draftPosition) }
    }
    func scheduleDraftSave() {
        draftSaveTask?.cancel()
        // Sending or explicitly clearing input must immediately remove the saved draft.
        if session?.draft.isEmpty == true {
            do { try saveDraft() } catch { self.error = "Could not save the draft: \(error)" }
            return
        }
        draftSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                try self.saveDraft()
            } catch is CancellationError {} catch { self?.error = "Could not save the draft: \(error)" }
        }
    }
    func renameCurrent(_ title: String) throws {
        try session?.rename(title); libraryRevision += 1
    }
    var library: ConversationLibrary { ConversationLibrary(paths: store.paths) }
    var title: String { session?.name ?? session?.messages.first(where: { $0.role == .user })?.text ?? "New conversation" }
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
        composerFocus += 1
    }

    func start() async {
        guard session == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try refreshProfiles()
            if let bookmark = try WorkspaceBookmark.load(paths: store.paths),
               let profile = try store.load().profile(bookmark.connectionID) {
                let file = bookmark.sessionFile.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                let restored = try await ChatSession.openCoding(cwd: bookmark.cwd, profile: profile, store: store, sessionFile: file)
                try await replace(restored, profile: profile, draftFile: bookmark.sessionFile)
                // A blank session has no JSONL yet. Save under its new identity before
                // advancing the bookmark, then retire the old draft only after both succeed.
                if file == nil, let previous = bookmark.sessionFile, let current = restored.sessionFile, previous != current {
                    try saveDraft()
                    try persistWorkspace()
                    try drafts.save("", for: previous)
                }
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
        try refreshProfiles()
        let next = try await ChatSession.openCoding(cwd: cwd, profile: profile, store: store)
        try await replace(next, profile: profile)
        remember()
    }
    func refreshProfiles() throws { profiles = try store.load().profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    func selectConnection(_ profile: ConnectionProfile) async {
        guard !busy, session?.isRunning != true, let session, session.workspace != nil, profile.id != self.profile?.id else { return }
        busy = true; defer { busy = false }
        do {
            try await session.selectConnection(profile, store: store)
            self.profile = profile; connection = profile.name; remember()
        } catch { self.error = String(describing: error) }
    }
    func rename(_ info: SessionInfo, title: String) throws {
        if session?.sessionFile == info.path { try session?.rename(title) }
        else { try library.rename(info.path, title: title) }
        libraryRevision += 1
    }
    func pin(_ info: SessionInfo, pinned: Bool) {
        do { try library.update(info.path, pinned: pinned); libraryRevision += 1 }
        catch { self.error = String(describing: error) }
    }
    func archive(_ info: SessionInfo, archived: Bool) async {
        guard !busy, session?.isRunning != true else { return }
        busy = true; defer { busy = false }
        do {
            // Finish the new-session operation before hiding the current conversation.
            if archived, session?.sessionFile == info.path {
                let draft = session?.draft ?? ""
                try saveDraft()
                try await session?.reset(); composerGeneration += 1; session?.draft = draft; remember()
                try saveDraft()
            }
            try library.update(info.path, archived: archived); libraryRevision += 1
        } catch { self.error = String(describing: error) }
    }
    func resume(_ info: SessionInfo) async throws {
        guard session?.isRunning != true, !busy else { throw PiError("Wait for the current operation to finish") }
        if session?.sessionFile == info.path { return }
        busy = true; defer { busy = false }
        let manager = try SessionManager.open(info.path)
        guard let id = CodingSessionHost.savedConnectionID(manager) else { throw PiError("This session has no saved connection. Open it with pf --connection NAME --session PATH first.") }
        guard let selected = try store.load().profile(id) else { throw PiError("Connect a model before opening this session") }
        let next = try await ChatSession.openCoding(cwd: info.cwd, profile: selected, store: store, sessionFile: info.path)
        try await replace(next, profile: selected)
        remember()
    }
    func unsentDrafts() throws -> [ConversationDraftStore.Draft] {
        guard let cwd else { return [] }
        return try drafts.unsent(cwd: cwd)
    }
    func resumeDraft(_ draft: ConversationDraftStore.Draft) async throws {
        guard !busy, session?.isRunning != true, let cwd else { return }
        if session?.sessionFile == draft.sessionFile { composerFocus += 1; return }
        busy = true; defer { busy = false }
        let selected: ConnectionProfile
        if let id = draft.connectionID {
            guard let saved = try store.load().profile(id) else { throw PiError("Restore this draft’s saved connection in Manage connections first.") }
            selected = saved
        } else {
            guard let current = profile else { throw PiError("Choose a connection to restore this older draft.") }
            selected = current
        }
        let next = try await ChatSession.openCoding(cwd: cwd, profile: selected, store: store)
        try await replace(next, profile: selected, draftFile: draft.sessionFile)
        // Keep the old recovery copy until both the new copy and bookmark are durable.
        try saveDraft()
        try persistWorkspace()
        try drafts.save("", for: draft.sessionFile)
        libraryRevision += 1; composerFocus += 1
    }
    func newConversation() async {
        do { try await startNewConversation() } catch { self.error = String(describing: error) }
    }
    func startNewConversation() async throws {
        guard !busy, let session, !session.isRunning else { throw PiError("Wait for the current operation to finish") }
        busy = true; defer { busy = false }
        try saveDraft(); try await session.reset()
        composerGeneration += 1; newConversationRequest += 1; composerFocus += 1; searchTerm = ""; remember()
    }
    func navigate(to id: String, fork: Bool, summarize: Bool, instructions: String) async throws {
        guard !busy, let session, !session.isRunning else { throw PiError("Wait for the current operation to finish") }
        busy = true; defer { busy = false }
        try saveDraft()
        try await session.navigate(to: id, fork: fork, summarize: summarize, instructions: instructions)
        composerGeneration += 1; composerFocus += 1; libraryRevision += 1; searchTerm = ""
        try saveDraft(); remember()
        commandNotice = fork ? "Fork created · edit the restored message to continue" : "Moved to selected point"
    }
    func selectCommandConnection(_ selected: ConnectionProfile) async throws {
        guard !busy, let session, !session.isRunning else { throw PiError("Wait for the current operation to finish") }
        if selected.id == profile?.id { return }
        busy = true; defer { busy = false }
        try await session.selectConnection(selected, store: store)
        profile = selected; connection = selected.name; remember()
    }
    func demo(_ scenario: DemoScenario, clearError: Bool = true) async {
        guard session?.isRunning != true else { return }
        do {
            let next = try makeDemoSession(scenario: scenario)
            try await replace(next, profile: nil)
            connection = "Offline demo · \(scenario.rawValue)"
            if clearError { error = nil }
        } catch { self.error = String(describing: error) }
    }
    func remember() {
        do { try persistWorkspace() }
        catch { self.error = "Could not save the last workspace: \(error)" }
    }
    private func persistWorkspace() throws {
        guard let session, let cwd = session.workspace, let id = session.connectionID else { return }
        try WorkspaceBookmark(cwd: cwd, connectionID: id, sessionFile: session.sessionFile).save(paths: store.paths)
    }
    func shutdown() async -> Bool {
        do { try saveDraft(); try persistWorkspace() }
        catch { self.error = "Could not save before quitting: \(error)"; return false }
        await session?.shutdown()
        return true
    }
    private func replace(_ next: ChatSession, profile: ConnectionProfile?, draftFile: String? = nil) async throws {
        do {
            try saveDraft()
            if let file = draftFile ?? next.sessionFile { next.draft = try drafts.load(for: file) }
        } catch {
            await next.shutdown()
            throw error
        }
        let old = session
        composerGeneration += 1; searchTerm = ""
        session = next; self.profile = profile; connection = profile?.name ?? "Offline demo"; error = nil
        await old?.shutdown()
    }
}
