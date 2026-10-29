import SwiftUI
import PiChat

struct PermissionModeMenu: View {
    let selected: ChatPermissionMode
    let select: (ChatPermissionMode) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mode").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(8)
            ForEach(ChatPermissionMode.allCases) { mode in
                Button { select(mode) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(mode == .bypassPermissions ? Color.orange : .primary)
                            Text(mode.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .medium))
                            .opacity(mode == selected ? 1 : 0).accessibilityHidden(true)
                    }
                }.buttonStyle(PermissionOptionStyle())
                    .accessibilityLabel(mode.title).accessibilityValue(mode == selected ? "Selected" : "")
                    .help(mode.detail)
            }
            Divider().padding(.vertical, 4)
            Text("Applies to this open conversation. Reopening starts in Manual.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            Text("Bypass skips app approvals, including shell commands. macOS permissions still apply. This workspace is not a sandbox.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(8)
        }.padding(6).frame(width: 310)
    }
}

private struct PermissionOptionStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(8).contentShape(Rectangle())
            .background(.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}
