#if os(macOS)
import AppKit
import SwiftUI
import PiChat
import PiUI

struct SessionDetails: View {
    let workspace: AppWorkspace
    let session: ChatSession
    let configure: () -> Void
    let close: () -> Void
    @State private var environmentExpanded = true
    @State private var contextExpanded = false
    @State private var toolsExpanded = true
    @State private var changesExpanded = true
    @State private var showsAllTools = false
    private var calls: [ChatToolCall] { session.displayedMessages.flatMap(\.tools) }
    private var changes: [ChatToolCall] { calls.filter { !($0.diff ?? "").isEmpty } }
    private var status: String {
        if !session.approvals.pending.isEmpty { return "Needs approval" }
        switch session.state {
        case .idle: return "Ready"
        case .running: return "Working"
        case .stopping: return "Stopping"
        case .completed: return "Completed"
        case .cancelled: return "Stopped"
        case .failed: return "Failed"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session details").font(.system(size: 13, weight: .medium))
                Spacer()
                Button(action: close) { ChatIcon(.close, size: 11).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close session details").accessibilityLabel("Close session details")
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 10) {
                    card("Environment", expanded: $environmentExpanded) {
                        if let cwd = workspace.cwd {
                            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder").font(.system(size: 15))
                                    Text(URL(fileURLWithPath: cwd).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Reveal workspace · \(cwd)").accessibilityLabel("Reveal workspace")
                        } else { note("Offline demo · no workspace") }
                        Button(action: configure) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "cpu").font(.system(size: 15))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(workspace.profile?.modelID ?? session.modelName).lineLimit(2).truncationMode(.middle)
                                    Text(workspace.connection).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                ChatIcon(.settings, size: 13).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(session.isRunning).help("Model & workspace").accessibilityLabel("Configure model and workspace")
                        row("Status", status)
                        if let file = session.sessionFile {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
                            } label: { Label("Reveal saved session", systemImage: "doc.text") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help(file)
                        }
                    }
                    card("Context", summary: session.usage.lastInput.map { "\($0.formatted()) tokens" } ?? "—", expanded: $contextExpanded) {
                        let usage = session.usage
                        if usage.reportedRequests > 0 {
                            row("Last input", usage.lastInput?.formatted() ?? "—")
                            row("Total input", usage.input.formatted())
                            row("Total output", usage.output.formatted())
                            if usage.cacheRead > 0 { row("Cache read", usage.cacheRead.formatted()) }
                            if usage.cacheWrite > 0 { row("Cache written", usage.cacheWrite.formatted()) }
                            note("Provider-reported tokens. Last input includes cache; totals cover reported requests in this conversation.")
                        } else {
                            note(workspace.profile == nil ? "The offline demo does not report token usage." : "Token usage appears when the model reports it.")
                        }
                    }
                    card("Tools", summary: "\(session.availableToolNames.count) available", expanded: $toolsExpanded) {
                        if !session.availableToolNames.isEmpty {
                            Text(session.availableToolNames.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if calls.isEmpty { note("No tools called in this conversation.") }
                        else {
                            ForEach(showsAllTools ? calls : Array(calls.suffix(5))) { ToolCallView(tool: $0) }
                            if calls.count > 5 {
                                Button(showsAllTools ? "Show recent calls" : "Show all \(calls.count) calls") { showsAllTools.toggle() }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                    }
                    card("Changes", summary: changes.isEmpty ? nil : "\(changes.count)", expanded: $changesExpanded) {
                        if changes.isEmpty { note("No recorded file diffs yet.") }
                        else {
                            note("Diffs recorded by tools in this conversation.")
                            ForEach(changes) { change in
                                DisclosureGroup {
                                    if let diff = change.diff {
                                        ScrollView([.horizontal, .vertical]) { DiffText(diff: diff) }
                                            .frame(height: min(200, CGFloat(diff.components(separatedBy: "\n").count) * 17 + 12))
                                    }
                                } label: {
                                    Label(changeName(change), systemImage: "doc.text")
                                        .lineLimit(1).truncationMode(.middle).help(changeName(change))
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 16)
            }
        }.font(.system(size: 12)).background(PiBrand.canvas)
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
    private func changeName(_ tool: ChatToolCall) -> String {
        guard let data = tool.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = args["path"] as? String else { return tool.name }
        return path
    }
    private func card<Content: View>(_ title: String, summary: String? = nil, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    ChatIcon(.right, size: 9).rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let summary { Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            if expanded.wrappedValue {
                VStack(alignment: .leading, spacing: 12, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 14)
            }
        }.overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.09), lineWidth: 1) }
    }
}
#endif
