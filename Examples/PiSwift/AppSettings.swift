#if os(macOS)
import SwiftUI
import PiUI

struct AppSettings: View {
    let workspace: AppWorkspace
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("conversationTextSize") private var textSize = 15.0
    @State private var showsConnection = false

    var body: some View {
        TabView {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    Picker("Conversation text size", selection: $textSize) {
                        ForEach(13...22, id: \.self) { size in Text("\(size) pt").tag(Double(size)) }
                    }
                    Text("Changes messages, code and the message editor. You can also use View → Text Size.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("A little room for a good idea.")
                        .font(.system(size: ChatTextSize.clamped(textSize)))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        .accessibilityLabel("Text size preview: A little room for a good idea.")
                    Button("Use default text size") { textSize = 15 }.disabled(textSize == 15)
                }
                Section("Accessibility") {
                    Text("Pi Swift follows macOS settings for increased contrast and reduced motion. Enable Keyboard navigation in System Settings to move between controls with Tab.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Section("Model & workspace") {
                    LabeledContent("Connection", value: workspace.profile?.name ?? "Offline demo")
                    LabeledContent("Model", value: workspace.profile?.modelID ?? "Offline fixture")
                    if let cwd = workspace.cwd {
                        LabeledContent("Folder") { Text(cwd).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
                    }
                    Button("Manage connections…") { showsConnection = true }
                        .disabled(workspace.busy || workspace.session?.isRunning == true)
                    Text("API keys stay in your Mac’s Keychain. Tool permissions are selected separately for each conversation.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.formStyle(.grouped).tabItem { Label("Connections", systemImage: "network") }
        }.padding(16).frame(width: 520, height: 460)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .sheet(isPresented: $showsConnection) { ConnectionSheet(workspace: workspace) }
    }
}

/// Menu actions belong to the focused conversation window, never to Settings or a sheet.
struct ConversationMenuActions {
    var newConversation: () -> Void
    var canCreateConversation: Bool
    var find: () -> Void
    var focusComposer: () -> Void
    var toggleSidebar: () -> Void
    var toggleDetails: () -> Void
    var help: () -> Void
    var showsSidebar: Bool
    var showsDetails: Bool
}
private struct ConversationMenuKey: FocusedValueKey { typealias Value = ConversationMenuActions }
extension FocusedValues {
    var conversationMenu: ConversationMenuActions? {
        get { self[ConversationMenuKey.self] }
        set { self[ConversationMenuKey.self] = newValue }
    }
}
struct ConversationCommands: Commands {
    @FocusedValue(\.conversationMenu) private var actions
    @AppStorage("conversationTextSize") private var textSize = 15.0
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { actions?.newConversation() }
                .keyboardShortcut("n").disabled(actions?.canCreateConversation != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find in Conversations…") { actions?.find() }
                .keyboardShortcut("f").disabled(actions == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(actions?.showsSidebar == true ? "Hide Sidebar" : "Show Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control]).disabled(actions == nil)
            Button(actions?.showsDetails == true ? "Hide Session Details" : "Show Session Details") { actions?.toggleDetails() }
                .keyboardShortcut("i", modifiers: [.command, .option]).disabled(actions == nil)
            Divider()
            Button("Focus Message Editor") { actions?.focusComposer() }
                .keyboardShortcut("l").disabled(actions == nil)
            Menu("Text Size") {
                Button("Larger") { textSize = ChatTextSize.clamped(textSize + 1) }
                    .keyboardShortcut("+", modifiers: .command).disabled(textSize >= ChatTextSize.range.upperBound)
                Button("Smaller") { textSize = ChatTextSize.clamped(textSize - 1) }
                    .keyboardShortcut("-", modifiers: .command).disabled(textSize <= ChatTextSize.range.lowerBound)
                Button("Actual Size") { textSize = 15 }.keyboardShortcut("0").disabled(textSize == 15)
            }.disabled(actions == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Pi Swift Command Reference") { actions?.help() }.disabled(actions == nil)
        }
    }
}
#endif
