import SwiftUI

/// Quiet, local feedback beside the composer; long diagnostics expand on demand.
public struct CommandFeedbackView: View {
    public let message: String
    public var isError: Bool
    public var isWorking: Bool
    public var dismiss: (() -> Void)?
    @State private var expanded = false
    public init(_ message: String, isError: Bool = false, isWorking: Bool = false, dismiss: (() -> Void)? = nil) {
        self.message = message; self.isError = isError; self.isWorking = isWorking; self.dismiss = dismiss
    }
    private var symbol: String {
        if isError { return "exclamationmark.circle" }
        if message.hasPrefix("Cancelled") { return "arrow.uturn.backward" }
        if message.hasPrefix("No ") || message.hasPrefix("Already") || message.contains("already compacted") { return "info.circle" }
        return "checkmark.circle"
    }
    public var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if isWorking { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).font(.system(size: 13)) }
            }.foregroundStyle(isError ? Color.orange : Color.secondary).frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                if isError { Text("Couldn’t complete this action").font(.system(size: 12, weight: .medium)) }
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if message.count > 130 || message.contains("\n") {
                    Button(expanded ? "Show less" : "Show details") { expanded.toggle() }
                        .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss, !isWorking {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Dismiss message").accessibilityLabel("Dismiss message")
            }
        }.padding(10)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.05)))
            .onChange(of: message) { expanded = false }
    }
}
