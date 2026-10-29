#if os(macOS)
import SwiftUI
import AppKit
import PiAI
import PiHost
import PiUI

struct ConnectionSheet: View {
    let workspace: AppWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [ConnectionProfile] = []
    @State private var selectedID = "new"
    @State private var name = ""
    @State private var endpoint = "https://api.openai.com/v1"
    @State private var modelID = ""
    @State private var thinkingLevels = ""
    @State private var apiKey = ""
    @State private var api = "openai-completions"
    @State private var cwd: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Model & workspace").font(.title2.weight(.semibold))
            Text("Keys stay in your Mac’s Keychain. Conversations are saved locally and shared with pf.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !profiles.isEmpty {
                Picker("Connection", selection: $selectedID) {
                    Text("New connection").tag("new")
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }.onChange(of: selectedID) { selectProfile() }
            }
            VStack(alignment: .leading, spacing: 12) {
                field("Name") { TextField("My model", text: $name).accessibilityLabel("Connection name") }
                Picker("API format", selection: $api) {
                    Text("OpenAI compatible").tag("openai-completions")
                    Text("OpenAI Responses").tag("openai-responses")
                    Text("Anthropic Messages").tag("anthropic-messages")
                }.onChange(of: api) {
                    if ["https://api.openai.com/v1", "https://api.anthropic.com"].contains(endpoint) {
                        endpoint = api == "anthropic-messages" ? "https://api.anthropic.com" : "https://api.openai.com/v1"
                    }
                }
                field("Base URL") { TextField("https://…", text: $endpoint).accessibilityLabel("Base URL") }
                field("Model ID") { TextField("Your provider’s model ID", text: $modelID).accessibilityLabel("Model ID") }
                field("Thinking levels · blank uses catalog capabilities") {
                    TextField("off, minimal, low, medium, high", text: $thinkingLevels).accessibilityLabel("Supported thinking levels")
                }
                field(selectedID == "new" ? "API key" : "API key · leave blank to keep saved key") {
                    SecureField("API key", text: $apiKey).accessibilityLabel("API key")
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace").font(.caption).foregroundStyle(.secondary)
                        Text(cwd ?? "Choose a folder for coding tools").font(.callout).lineLimit(1).truncationMode(.middle).help(cwd ?? "")
                    }
                    Spacer()
                    Button("Choose folder…", action: chooseFolder).buttonStyle(ChatButtonStyle())
                }.padding(.top, 4)
                Text("Each tool call asks for approval. File changes include a preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(ChatButtonStyle()).keyboardShortcut(.cancelAction)
                if let selected = profiles.first(where: { $0.id == selectedID }) {
                    Button("Forget key") {
                        Task {
                            saving = true; error = nil; notice = nil; defer { saving = false }
                            let store = workspace.store
                            do {
                                try await Task.detached { try store.forgetKey(for: selected) }.value
                                apiKey = ""; notice = "Saved key removed. Existing connections remain active until closed."
                            } catch { self.error = String(describing: error) }
                        }
                    }.buttonStyle(ChatButtonStyle())
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Open workspace") { Task { await connect() } }.buttonStyle(ChatButtonStyle(.primary))
                    .disabled(cwd == nil || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 460).disabled(saving).interactiveDismissDisabled(saving)
            .task {
                cwd = workspace.cwd
                do {
                    let catalog = try workspace.store.load(); profiles = catalog.profiles
                    selectedID = workspace.profile?.id ?? catalog.defaultID ?? "new"
                    selectProfile()
                } catch { self.error = String(describing: error) }
            }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.plain).padding(9).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func selectProfile() {
        apiKey = ""; thinkingLevels = ""; error = nil; notice = nil
        if let profile = profiles.first(where: { $0.id == selectedID }) {
            thinkingLevels = profile.thinkingLevels?.map(\.rawValue).joined(separator: ", ") ?? ""
            name = profile.name; api = profile.api; endpoint = profile.endpoint; modelID = profile.modelID
        } else { name = ""; modelID = ""; api = "openai-completions"; endpoint = "https://api.openai.com/v1" }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Use workspace"
        if panel.runModal() == .OK { cwd = panel.url?.standardizedFileURL.path }
    }
    private func connect() async {
        guard let cwd else { return }
        saving = true; error = nil; defer { saving = false }
        let existing = profiles.first { $0.id == selectedID }
        let sameRoute = existing?.api == api && existing?.endpoint == endpoint
        let values = thinkingLevels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let levels = values.compactMap(ModelThinkingLevel.init(rawValue:))
        guard values.count == levels.count else { error = "Use off, minimal, low, medium, high, xhigh, or max, separated by commas."; return }
        let profile = ConnectionProfile(id: sameRoute ? selectedID : UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            api: api, endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), provider: existing?.provider ?? "custom", thinkingLevels: levels.isEmpty ? nil : levels)
        do {
            try await workspace.connect(profile: profile, key: apiKey.isEmpty ? nil : apiKey, cwd: cwd)
            apiKey = ""; dismiss()
        } catch { self.error = String(describing: error) }
    }
}
#endif
