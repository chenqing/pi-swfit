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
    var body: some Scene {
        WindowGroup("Pi Playground") { Playground().frame(minWidth: 640, minHeight: 560) }
            .defaultSize(width: 860, height: 760).windowStyle(.hiddenTitleBar)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct Playground: View {
    @State private var session: ChatSession?
    @State private var error: String?
    @State private var connection = "Offline demo"
    @State private var showConnection = false
    @State private var compact = false
    @State private var appearance = "system"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("π").font(.system(size: 25, weight: .medium, design: .serif)).foregroundStyle(playgroundAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pi Playground").font(.system(size: 13, weight: .semibold))
                    Text(connection).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let session {
                    Menu {
                        ForEach(DemoScenario.allCases, id: \.self) { scenario in
                            Button(scenario.rawValue == "tool" ? "Tool approval" : scenario.rawValue == "failure" ? "Connection failure" : "Long streaming reply") {
                                loadDemo(scenario)
                            }
                        }
                    } label: { Label("Scenarios", systemImage: "play.rectangle") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(session.isRunning)
                    Button { compact.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help("Toggle compact layout").accessibilityLabel("Toggle compact layout")
                    Button { Task { do { try await session.reset() } catch { self.error = String(describing: error) } } } label: { Image(systemName: "square.and.pencil") }
                        .help("New conversation").accessibilityLabel("New conversation").disabled(session.isRunning)
                    Menu {
                        Picker("Appearance", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                    } label: { Image(systemName: "circle.lefthalf.filled") }
                        .menuStyle(.borderlessButton).fixedSize().help("Appearance").accessibilityLabel("Appearance")
                    Button { showConnection = true } label: { Image(systemName: "slider.horizontal.3") }
                        .help("Connect a model").accessibilityLabel("Connect a model").disabled(session.isRunning)
                }
            }.buttonStyle(.plain).padding(.horizontal, 26).padding(.top, 30).padding(.bottom, 14)
            if let session {
                HStack(spacing: 0) {
                    if compact { contextExample.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    ConversationView(session: session).frame(maxWidth: compact ? 440 : .infinity)
                }
            } else if let error { Text(error).padding() }
        }.background(Color(nsColor: .textBackgroundColor))
            .chatTheme(ChatTheme(accent: playgroundAccent, accentForeground: playgroundOnAccent))
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .task { if session == nil { loadDemo(.tool) } }
            .sheet(isPresented: $showConnection) {
                ConnectionSheet { newSession, name in session = newSession; connection = name }
                    .chatTheme(ChatTheme(accent: playgroundAccent, accentForeground: playgroundOnAccent))
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
    private func loadDemo(_ scenario: DemoScenario) {
        do { session = try makeDemoSession(scenario: scenario); connection = "Offline demo · \(scenario.rawValue)"; error = nil }
        catch { self.error = String(describing: error) }
    }
}

struct ConnectionSheet: View {
    let connect: (ChatSession, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = "https://api.openai.com/v1"
    @State private var modelID = ""
    @State private var apiKey = ""
    @State private var api = "openai-completions"
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect your model").font(.title2.weight(.semibold))
            Text("Your key stays in memory for this session. Requests go directly to the endpoint you choose.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API format").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("OpenAI compatible") { selectAPI("openai-completions") }
                        Button("OpenAI Responses") { selectAPI("openai-responses") }
                        Button("Anthropic Messages") { selectAPI("anthropic-messages") }
                    } label: {
                        HStack {
                            Text(api == "anthropic-messages" ? "Anthropic Messages" : api == "openai-responses" ? "OpenAI Responses" : "OpenAI compatible")
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(10).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("API format")
                }
                field("Base URL") { TextField("https://…", text: $endpoint) }
                field("Model ID") { TextField("Your provider's model ID", text: $modelID) }
                field("API key") { SecureField("API key", text: $apiKey) }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(ChatButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use model") { openConnection() }.buttonStyle(ChatButtonStyle(.primary))
                    .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 440)
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.plain).padding(10).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func selectAPI(_ value: String) {
        api = value
        if ["https://api.openai.com/v1", "https://api.anthropic.com"].contains(endpoint) {
            endpoint = value == "anthropic-messages" ? "https://api.anthropic.com" : "https://api.openai.com/v1"
        }
    }
    private func openConnection() {
        guard let url = URL(string: endpoint), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            error = "Use an HTTPS endpoint, or HTTP on localhost."; return
        }
        do {
            let key = apiKey
            let model = Model(id: modelID.trimmingCharacters(in: .whitespacesAndNewlines), name: modelID,
                              api: api, provider: "custom", baseUrl: endpoint, input: ["text"], contextWindow: 128_000, maxTokens: 4096)
            let session = try ChatSession(options: AgentOptions(initialState: AgentInitialState(systemPrompt: "You are a helpful assistant.", model: model), getApiKey: { _ in key.isEmpty ? nil : key }))
            connect(session, model.id); apiKey = ""; dismiss()
        } catch { self.error = String(describing: error) }
    }
}
#else
@main struct PiPlaygroundApp { static func main() { print("PiPlayground requires macOS.") } }
#endif
