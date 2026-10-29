import SwiftUI
import PiChat
import PiHost

/// Host-owned controls; the composer does not choose models or alter tool permissions.
public struct ComposerContext {
    public struct ModelChoice: Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let selected: Bool
        public let select: () -> Void
        public init(id: String, title: String, detail: String, selected: Bool, select: @escaping () -> Void) {
            self.id = id; self.title = title; self.detail = detail; self.selected = selected; self.select = select
        }
    }
    public var model: String
    public var policy: String
    public var configure: () -> Void
    public var addTextFile: () -> Void
    public var modelChoices: [ModelChoice]
    public var commandNotice: String?
    public var commands: [CommandDescriptor]
    public var submitCommand: ((String) -> Void)?
    public var permissionMode: ChatPermissionMode?
    public var canSelectPermissionMode: Bool
    public var selectPermissionMode: ((ChatPermissionMode) -> Void)?
    public init(model: String, policy: String, configure: @escaping () -> Void, addTextFile: @escaping () -> Void, modelChoices: [ModelChoice] = [],
                permissionMode: ChatPermissionMode? = nil, canSelectPermissionMode: Bool = true,
                selectPermissionMode: ((ChatPermissionMode) -> Void)? = nil, submitCommand: ((String) -> Void)? = nil, commandNotice: String? = nil, commands: [CommandDescriptor] = CommandDescriptor.builtins()) {
        self.model = model; self.policy = policy; self.configure = configure; self.addTextFile = addTextFile
        self.modelChoices = modelChoices; self.submitCommand = submitCommand; self.commandNotice = commandNotice; self.commands = commands
        self.permissionMode = permissionMode; self.canSelectPermissionMode = canSelectPermissionMode
        self.selectPermissionMode = selectPermissionMode
    }
}

public struct Composer: View {
    @Binding private var text: String
    private let isRunning: Bool
    private let send: () -> Void
    private let stop: () -> Void
    private let context: ComposerContext?
    private let identity: String
    private let focusRequest: Int
    @State private var focused = false
    @State private var editorHeight: CGFloat = 28
    @State private var addingContent = false
    @State private var choosingPermissions = false
    @State private var commandIndex = 0
    @State private var dismissedCommands = false
    private var commands: [CommandDescriptor] {
        guard context?.submitCommand != nil, !isRunning, !dismissedCommands else { return [] }
        return CommandDescriptor.suggestions(text, catalog: context?.commands ?? [])
    }
    @FocusState private var fallbackFocused: Bool
    public init(text: Binding<String>, isRunning: Bool, context: ComposerContext? = nil, identity: String = "", focusRequest: Int = 0, send: @escaping () -> Void, stop: @escaping () -> Void) {
        self.identity = identity; self.focusRequest = focusRequest
        _text = text; self.isRunning = isRunning; self.context = context; self.send = send; self.stop = stop
    }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !commands.isEmpty {
                SlashCommandMenu(commands: commands, selected: commandIndex) { command in
                    complete(command)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if let context {
                    Button { addingContent.toggle() } label: {
                        ChatIcon(.add, size: 18)
                            .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(ComposerControlStyle()).foregroundStyle(.secondary)
                        .help("Add content").accessibilityLabel("Add content")
                        .popover(isPresented: $addingContent, arrowEdge: .top) {
                            Button {
                                addingContent = false
                                context.addTextFile()
                            } label: {
                                Label { Text("Insert text file…") } icon: { ChatIcon(.file, size: 14) }
                                    .font(.system(size: 13)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(ComposerControlStyle()).padding(5).frame(width: 200)
                        }
                        .onChange(of: addingContent) { if !addingContent { focused = true } }
                }
                editor
                if isRunning {
                    Button(action: stop) {
                        ChatIcon(.stop, size: 10).frame(width: 28, height: 28)
                            .background(.primary.opacity(0.08), in: Circle())
                    }.buttonStyle(ComposerControlStyle()).help("Stop generation").accessibilityLabel("Stop generation")
                } else if canSend {
                    Button(action: submit) {
                        ChatIcon(.send, size: 17).frame(width: 28, height: 28)
                            .foregroundStyle(.primary).contentShape(Rectangle())
                    }.buttonStyle(ComposerControlStyle())
                        .help(text.hasPrefix("/") ? "Run command · Return" : "Send message · Return").accessibilityLabel(text.hasPrefix("/") ? "Run command" : "Send message")
                }
            }.padding(.horizontal, 8).padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 14).fill(.background)
                        .onTapGesture { focused = true; fallbackFocused = true }
                }
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(focused ? 0.20 : 0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
                .animation(.easeOut(duration: 0.15), value: focused)
            if let notice = context?.commandNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            HStack(spacing: 12) {
                if let context, let mode = context.permissionMode, let select = context.selectPermissionMode {
                    Button { choosingPermissions.toggle() } label: {
                        HStack(spacing: 5) {
                            Text(mode.title)
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }.foregroundStyle(mode == .bypassPermissions ? Color.orange : .secondary)
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(isRunning || !context.canSelectPermissionMode)
                        .layoutPriority(1)
                        .help(isRunning ? "Wait for this response to finish before changing permissions" : mode.detail)
                        .accessibilityLabel("Permissions: \(mode.title)")
                        .popover(isPresented: $choosingPermissions, arrowEdge: .bottom) {
                            PermissionModeMenu(selected: mode) { choice in
                                select(choice); choosingPermissions = false
                            }
                        }
                        .onChange(of: isRunning) { if isRunning { choosingPermissions = false } }
                        .onChange(of: identity) { choosingPermissions = false }
                        .onChange(of: choosingPermissions) { if !choosingPermissions { focused = true } }
                } else {
                    Text(context?.policy ?? (isRunning ? "You can prepare your next message" : "Return to send · ⇧ Return for a new line"))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false).help(context?.policy ?? "Return to send · ⇧ Return for a new line")
                }
                Spacer(minLength: 8)
                if let context {
                    Menu {
                        if context.modelChoices.isEmpty { Text("No saved models for this workspace") }
                        ForEach(context.modelChoices) { choice in
                            Button(action: choice.select) {
                                if choice.selected { Label("\(choice.title) · \(choice.detail)", systemImage: "checkmark") }
                                else { Text("\(choice.title) · \(choice.detail)") }
                            }
                        }
                        Divider()
                        Button("Manage connections…", action: context.configure)
                    } label: {
                        Text(context.model).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: context.permissionMode == .bypassPermissions ? 180 : 220, alignment: .trailing)
                    }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().disabled(isRunning)
                        .tint(.primary)
                        .help("Choose model · \(context.model)").accessibilityLabel("Model: \(context.model)")
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(minHeight: 20)
        }
        .onChange(of: text) { commandIndex = 0; dismissedCommands = false }
        .onChange(of: identity) { commandIndex = 0; dismissedCommands = false }
    }
    private func complete(_ command: CommandDescriptor) {
        text = "/" + command.name + (command.argumentHint == nil ? "" : " ")
        dismissedCommands = true
        focused = true; fallbackFocused = true
    }
    private func commandKey(_ key: UInt16) -> Bool {
        guard !commands.isEmpty else { return false }
        switch key {
        case 125: commandIndex = (commandIndex + 1) % commands.count
        case 126: commandIndex = (commandIndex + commands.count - 1) % commands.count
        case 53: dismissedCommands = true
        case 48: complete(commands[min(commandIndex, commands.count - 1)])
        case 36, 76:
            let choice = commands[min(commandIndex, commands.count - 1)]
            if text == "/" + choice.name { submit() }
            else { complete(choice) }
        default: return false
        }
        return true
    }
    private func submit() {
        guard canSend, !isRunning, !addingContent, !choosingPermissions else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"), let command = context?.submitCommand {
            dismissedCommands = true
            command(text)
        } else { send() }
        focused = true
        fallbackFocused = true
    }
    @ViewBuilder private var editor: some View {
        #if os(macOS)
        ComposerEditor(text: $text, focused: $focused, height: $editorHeight, identity: identity, focusRequest: focusRequest, commandKey: commandKey, submit: submit)
            .frame(height: editorHeight)
            .help("Return to send · Shift-Return for a new line")
        #else
        TextField("Ask something…", text: $text, axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...8)
            .focused($fallbackFocused).accessibilityLabel("Message").padding(.vertical, 4)
        #endif
    }

}


private struct ComposerControlStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.10 : hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}
