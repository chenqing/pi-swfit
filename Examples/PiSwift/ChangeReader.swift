#if os(macOS)
import SwiftUI
import AppKit
import PiChat
import PiUI

/// A separate window keeps the conversation and its composer usable while reading changes.
@MainActor final class ChangeReaderWindow: NSWindowController {
    init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func present(changes: [RecordedChange], selected: String, appearance: String) {
        guard let index = changes.firstIndex(where: { $0.id == selected }) else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Recorded edits"
            window.minSize = NSSize(width: 620, height: 420)
            window.isReleasedWhenClosed = false
            window.center(); self.window = window
        }
        window?.appearance = appearance == "system" ? nil : NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let size = window?.contentLayoutRect.size ?? NSSize(width: 960, height: 680)
        window?.contentViewController = NSHostingController(rootView: ChangeReader(changes: changes, index: index) { [weak self] in self?.close() })
        window?.setContentSize(size)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
}

struct ChangeReader: View {
    let changes: [RecordedChange]
    @State var index: Int
    let close: () -> Void
    @State private var copied = false
    @State private var wrap = true
    @State private var hunk = 0
    @Environment(\.colorScheme) private var scheme
    private var change: RecordedChange { changes[index] }
    var body: some View {
        let parsed = RecordedDiff(change.diff)
        let unwrappedWidth = parsed.lines.reduce(CGFloat(112)) { width, line in
            max(width, (line.text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width + 112)
        }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    if changes.count > 1 {
                        Picker("Recorded edit", selection: $index) {
                            ForEach(changes.indices, id: \.self) { i in Text("\(i + 1). \(changes[i].path)").tag(i) }
                        }.labelsHidden().frame(maxWidth: 420)
                    } else {
                        Text(change.path).font(.system(size: 14, weight: .medium)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    Text("Edit \(index + 1) of \(changes.count) · \(change.added) added · \(change.removed) removed")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(change.diff, forType: .string); copied = true
                } label: { Label(copied ? "Copied" : "Copy diff", systemImage: copied ? "checkmark" : "square.on.square") }
                    .buttonStyle(.borderless)
                    .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Toggle("Wrap lines", isOn: $wrap).toggleStyle(.checkbox)
                        Spacer()
                        Text(parsed.hunks.isEmpty ? "No hunks" : "Hunk \(hunk + 1) of \(parsed.hunks.count)")
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button { hunk -= 1; proxy.scrollTo(parsed.hunks[hunk], anchor: .top) } label: {
                            Image(systemName: "chevron.up").frame(width: 22, height: 22)
                        }.disabled(hunk == 0 || parsed.hunks.isEmpty).help("Previous hunk").accessibilityLabel("Previous hunk")
                        Button { hunk += 1; proxy.scrollTo(parsed.hunks[hunk], anchor: .top) } label: {
                            Image(systemName: "chevron.down").frame(width: 22, height: 22)
                        }.disabled(hunk + 1 >= parsed.hunks.count).help("Next hunk").accessibilityLabel("Next hunk")
                    }.buttonStyle(.borderless).font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    GeometryReader { geometry in
                        ScrollView(wrap ? [.vertical] : [.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(parsed.lines) { line in
                                    diffLine(line).id(line.id)
                                }
                            }.frame(width: wrap ? geometry.size.width : max(geometry.size.width, unwrappedWidth), alignment: .leading)
                                .padding(.vertical, 8)
                        }
                    }
                }.onChange(of: index) {
                    hunk = 0; copied = false
                    proxy.scrollTo(0, anchor: .top)
                }
            }
            Divider()
            Text("Recorded tool edit · Old / new line numbers · The file may have changed since.")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.background(PiBrand.canvas)
    }
    private func diffLine(_ line: RecordedDiff.Line) -> some View {
        let add = line.kind == .added, remove = line.kind == .removed
        return HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing).padding(.trailing, 12)
            Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading).padding(.trailing, 16)
        }.font(.system(size: 13, design: .monospaced)).padding(.vertical, 3)
            .foregroundStyle(add ? (scheme == .dark ? Color.green : Color(red: 0.12, green: 0.40, blue: 0.24)) : remove ? (scheme == .dark ? Color.red : Color(red: 0.68, green: 0.18, blue: 0.20)) : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(add ? Color.green.opacity(0.08) : remove ? Color.red.opacity(0.07) : line.kind == .hunk ? Color.primary.opacity(0.035) : Color.clear)
    }
}
#endif
