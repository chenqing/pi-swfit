#if os(macOS)
import SwiftUI
import AppKit
import PiChat
import PiUI

struct ChangeReader: View {
    let change: RecordedChange
    let width: CGFloat
    let height: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme
    private var lines: [(text: String, kind: Int)] {
        var inHunk = false
        return change.diff.components(separatedBy: "\n").map { line in
            if line.hasPrefix("diff --git ") { inHunk = false }
            if line.hasPrefix("@@ ") { inHunk = true; return (line, 2) }
            return (line, inHunk && line.hasPrefix("+") ? 1 : inHunk && line.hasPrefix("-") ? -1 : 0)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(change.path).font(.system(size: 14, weight: .medium)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Text("Recorded edit · \(change.added) added · \(change.removed) removed")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(change.diff, forType: .string); copied = true
                } label: { Label(copied ? "Copied" : "Copy diff", systemImage: copied ? "checkmark" : "square.on.square") }
                    .buttonStyle(.borderless)
                    .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
                        let line = item.text, add = item.kind == 1, remove = item.kind == -1
                        HStack(spacing: 0) {
                            Text(line.isEmpty ? " " : line).textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 3)
                            Spacer(minLength: 16)
                        }.frame(minWidth: width - 2, alignment: .leading)
                            .foregroundStyle(add ? (colorScheme == .dark ? Color.green : Color(red: 0.12, green: 0.40, blue: 0.24)) : remove ? (colorScheme == .dark ? Color.red : Color(red: 0.68, green: 0.18, blue: 0.20)) : Color.primary.opacity(0.75))
                            .background(add ? Color.green.opacity(0.08) : remove ? Color.red.opacity(0.07) : line.hasPrefix("@@") ? Color.primary.opacity(0.035) : Color.clear)
                    }
                }.font(.system(size: 13, design: .monospaced)).fixedSize(horizontal: true, vertical: false).padding(.vertical, 10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text("This is the edit recorded in this conversation. The file may have changed since.")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.frame(width: width, height: height).background(PiBrand.canvas)
    }
}
#endif
