import SwiftUI
import Observation
#if os(macOS)
import AppKit

/// Native, selectable block Markdown. Images and HTML are represented as text.
public struct MarkdownMessage: View {
    public let source: String
    @State private var rendering = MarkdownRendering()
    public init(_ source: String) { self.source = source }
    public var body: some View {
        MarkdownBlocks(blocks: rendering.blocks)
            .onChange(of: source, initial: true) { rendering.update(source) }
            .onAppear { rendering.update(source) }
            .onDisappear { rendering.cancel() }
    }
}

@MainActor @Observable
final class MarkdownRendering {
    private(set) var blocks: [MarkdownBlock] = []
    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var rendered: String?
    @ObservationIgnored private var worker: Task<Void, Never>?

    func update(_ source: String) {
        pending = source
        guard worker == nil, rendered != source else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled {
                let snapshot = pending
                let parsed = await Task.detached(priority: .userInitiated) { MarkdownParser.parse(snapshot) }.value
                guard !Task.isCancelled else { return }
                blocks = parsed; rendered = snapshot
                // Coalesce deltas while preserving visible progress during a continuous stream.
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                if pending == rendered { worker = nil; return }
            }
        }
    }
    func cancel() { worker?.cancel(); worker = nil }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in MarkdownBlockView(block: block) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    @Environment(\.chatTheme) private var theme
    var body: some View {
        switch block {
        case .paragraph(let runs): MarkdownInline(runs: runs).font(theme.bodyFont)
        case .heading(let level, let runs):
            MarkdownInline(runs: runs)
                .font(.system(size: theme.textSize + (level == 1 ? 10 : level == 2 ? 5 : level == 3 ? 2 : 0), weight: .semibold))
                .padding(.top, 5).accessibilityAddTraits(.isHeader)
        case .code(let language, let source): MarkdownCodeBlock(language: language, source: source)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                MarkdownBlocks(blocks: blocks).foregroundStyle(ChatPalette.secondaryText)
            }.padding(.leading, 14).padding(.vertical, 3)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(0.35)).frame(width: 3) }
        case .list(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? theme.accent : .secondary)
                                    .accessibilityLabel(checked ? "Completed" : "Not completed")
                            } else { Text(item.marker).foregroundStyle(ChatPalette.secondaryText) }
                        }.font(theme.bodyFont).frame(minWidth: 20, alignment: .trailing).padding(.top, 2)
                        MarkdownBlocks(blocks: item.blocks)
                    }
                }
            }
        case .table(let headers, let rows, let alignments):
            MarkdownTable(headers: headers, rows: rows, alignments: alignments)
        case .divider: Rectangle().fill(.primary.opacity(0.09)).frame(height: 1).padding(.vertical, 5)
        }
    }
}

private struct MarkdownInline: View {
    @Environment(\.chatTheme) private var theme
    let runs: [MarkdownRun]
    var body: some View {
        Text(attributed).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    private var attributed: AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var part = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.emphasis { intent.insert(.emphasized) }
            if run.strong { intent.insert(.stronglyEmphasized) }
            if run.strike { intent.insert(.strikethrough) }
            if run.code { intent.insert(.code); part.font = .system(size: theme.codeSize, design: .monospaced); part.backgroundColor = .primary.opacity(0.045) }
            part.inlinePresentationIntent = intent
            part.link = run.link
            result += part
        }
    }
}

private struct MarkdownCodeBlock: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chatTheme) private var theme
    let language: String?
    let source: String
    @State private var copied = false
    private var displayed: String { source.hasSuffix("\n") ? String(source.dropLast()) : source }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "Code").lineLimit(1)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                    copied = true
                } label: {
                    Label { Text(copied ? "Copied" : "Copy") } icon: { ChatIcon(copied ? .check : .copy, size: 13) }
                        .frame(minWidth: 52, alignment: .trailing).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Copy code").accessibilityLabel(copied ? "Code copied" : "Copy code")
                    .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(ChatPalette.secondaryText).padding(.horizontal, 14).padding(.vertical, 8)
            Rectangle().fill(.primary.opacity(0.055)).frame(height: 1)
            ScrollView([.horizontal, .vertical]) {
                Text(displayed.isEmpty ? " " : displayed).font(.system(size: theme.codeSize, design: .monospaced))
                    .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(360, CGFloat(displayed.components(separatedBy: "\n").count) * (theme.codeSize + 7) + 28))
        }.background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.07), lineWidth: 1) }
    }
}

private struct MarkdownTable: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chatTheme) private var theme
    let headers: [[MarkdownRun]]
    let rows: [[[MarkdownRun]]]
    let alignments: [MarkdownAlignment]
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                row(headers, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in row(cells, header: false) }
            }.background(.primary.opacity(0.02)).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.07), lineWidth: 1) }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func row(_ cells: [[MarkdownRun]], header: Bool) -> some View {
        GridRow(alignment: .top) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, runs in
                let alignment: Alignment = index < alignments.count && alignments[index] == .right ? .trailing : index < alignments.count && alignments[index] == .center ? .center : .leading
                MarkdownInline(runs: runs).font(.system(size: theme.codeSize, weight: header ? .semibold : .regular))
                    .frame(width: 160, alignment: alignment).padding(12)
                    .background(header ? Color.primary.opacity(0.035) : .clear)
                    .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.06)).frame(height: 1) }
            }
        }
    }
}
#endif
