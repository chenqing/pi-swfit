import SwiftUI
import PiChat

public struct ApprovalView: View {
    public let approval: ChatApproval
    @State private var argumentsHeight: CGFloat = 20
    private let decide: (Bool) -> Void
    public init(approval: ChatApproval, decide: @escaping (Bool) -> Void) { self.approval = approval; self.decide = decide }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text("Allow \(approval.toolName)?") } icon: { ChatIcon(.approval, size: 14) }.font(.system(size: 14, weight: .medium))
            if let preview = approval.preview {
                ScrollView([.horizontal, .vertical]) { DiffText(diff: preview) }
                    .frame(height: min(180, max(70, CGFloat(preview.components(separatedBy: "\n").count) * 16)))
            } else {
                ScrollView {
                    Text(approval.arguments == "{}" ? "No arguments · The tool will run once." : approval.arguments)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ApprovalArgumentsHeight.self, value: geometry.size.height)
                        })
                }.frame(height: min(100, argumentsHeight))
                    .onPreferenceChange(ApprovalArgumentsHeight.self) { argumentsHeight = $0 }
            }
            HStack {
                Text("Permission for this call only").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Decline") { decide(false) }.buttonStyle(ChatButtonStyle())
                Button("Allow") { decide(true) }.buttonStyle(ChatButtonStyle(.primary))
            }
        }.padding(16).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

private struct ApprovalArgumentsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 20
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
