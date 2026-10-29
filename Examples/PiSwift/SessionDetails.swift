#if os(macOS)
import AppKit
import SwiftUI
import Observation
import PiChat
import PiUI

@Observable final class DetailsExpansion {
    var environment = true
    var usage = false
    var tools = false
    var changes = true
    var rawTools: Set<String> = []
}

struct SessionDetails: View {
    let workspace: AppWorkspace
    let session: ChatSession
    @Bindable var expansion: DetailsExpansion
    var compact = false
    let openChange: (RecordedChange) -> Void
    let close: () -> Void
    @State private var showsAllTools = false
    private var calls: [ChatToolCall] { session.displayedMessages.flatMap(\.tools) }
    private var changes: [RecordedChange] { calls.compactMap(RecordedChange.init) }
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
            if compact {
                HStack {
                    Text("Session details").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button(action: close) { ChatIcon(.close, size: 11).frame(width: 28, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Close session details").accessibilityLabel("Close session details")
                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
            }
            ScrollView {
                VStack(spacing: 10) {
                    card("Environment", expanded: $expansion.environment) {
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
                        row("Status", status)
                    }
                    card("Usage", summary: session.usage.lastInput.map { "\($0.formatted()) in" } ?? "—", expanded: $expansion.usage) {
                        let usage = session.usage
                        if usage.reportedRequests > 0 {
                            row("Last input", usage.lastInput?.formatted() ?? "—")
                            row("Total input", usage.input.formatted())
                            row("Total output", usage.output.formatted())
                            if usage.cacheRead > 0 { row("Cache read", usage.cacheRead.formatted()) }
                            if usage.cacheWrite > 0 { row("Cache written", usage.cacheWrite.formatted()) }
                            note("Reported tokens, not context capacity. Last input includes cache; totals cover reported requests.")
                        } else { note(workspace.profile == nil ? "The offline demo does not report token usage." : "Token usage appears when the model reports it.") }
                    }
                    card("Tools", summary: calls.isEmpty ? "\(session.availableToolNames.count) available" : "\(calls.count) \(calls.count == 1 ? "call" : "calls")", expanded: $expansion.tools) {
                        if !session.availableToolNames.isEmpty {
                            Text(session.availableToolNames.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if calls.isEmpty { note("No tools called yet.") }
                        else {
                            ForEach(showsAllTools ? calls : Array(calls.suffix(5))) { tool in toolRow(tool) }
                            if calls.count > 5 {
                                Button(showsAllTools ? "Show recent calls" : "Show all \(calls.count) calls") { showsAllTools.toggle() }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                    }
                    card("Changes", summary: changes.isEmpty ? nil : "\(changes.count) \(changes.count == 1 ? "edit" : "edits")", expanded: $expansion.changes) {
                        if changes.isEmpty { note("No recorded file edits yet.") }
                        else {
                            ForEach(changes) { change in
                                Button { openChange(change) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                                        Text(displayPath(change.path)).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 4)
                                        Text("+\(change.added)").foregroundStyle(.green)
                                        Text("−\(change.removed)").foregroundStyle(.red)
                                    }.monospacedDigit().padding(.vertical, 5).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Read recorded diff · \(change.path)")
                                    .accessibilityLabel("View diff for \(displayPath(change.path)), \(change.added) added, \(change.removed) removed")
                            }
                            note("Select an edit to read its recorded diff.")
                        }
                    }
                }.padding(.horizontal, 12).padding(.top, compact ? 0 : 8).padding(.bottom, 16)
            }
        }.font(.system(size: 12)).background(PiBrand.canvas)
    }
    private func toolRow(_ tool: ChatToolCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if !expansion.rawTools.insert(tool.id).inserted { expansion.rawTools.remove(tool.id) }
            } label: {
                HStack(spacing: 7) {
                    if tool.state == .running { ProgressView().controlSize(.mini) }
                    else { ChatIcon(tool.state == .succeeded ? .check : tool.state == .failed ? .failure : .waiting, size: 12) }
                    Text(tool.name)
                    if let path = RecordedChange.path(for: tool) {
                        Text(displayPath(path)).lineLimit(1).truncationMode(.middle)
                    } else if tool.state != .succeeded { Text(tool.state.rawValue.capitalized).lineLimit(1) }
                    Spacer(minLength: 0)
                    ChatIcon(.right, size: 9).rotationEffect(.degrees(expansion.rawTools.contains(tool.id) ? 90 : 0))
                }.foregroundStyle(.secondary).padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Show raw tool details")
                .accessibilityLabel("\(tool.name), \(tool.state.rawValue)")
                .accessibilityValue(expansion.rawTools.contains(tool.id) ? "Expanded" : "Collapsed")
            if expansion.rawTools.contains(tool.id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Arguments").foregroundStyle(.secondary)
                        Text(tool.arguments).font(.system(size: 11, design: .monospaced))
                        if !tool.output.isEmpty {
                            Text("Result").foregroundStyle(.secondary)
                            Text(tool.output).font(.system(size: 11, design: .monospaced))
                        }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 140).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func displayPath(_ path: String) -> String {
        guard let cwd = workspace.cwd, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
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
