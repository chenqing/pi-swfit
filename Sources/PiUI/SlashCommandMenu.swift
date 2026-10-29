import SwiftUI
import PiHost

struct SlashCommandMenu: View {
    let commands: [SlashCommand]
    let selected: Int
    let choose: (SlashCommand) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Commands").fontWeight(.medium)
                Spacer()
                Text("↑↓ select · Tab complete · Esc close")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            Button { choose(command) } label: {
                                HStack(spacing: 12) {
                                    Text("/" + command.rawValue).font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 84, alignment: .leading)
                                    Text(command.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(index == selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(command.id)
                                .accessibilityLabel("/\(command.rawValue), \(command.summary)")
                                .accessibilityValue(index == selected ? "Selected" : "")
                        }
                    }
                }.frame(height: CGFloat(min(commands.count, 5)) * 38)
                    .onChange(of: selected) { if commands.indices.contains(selected) { proxy.scrollTo(commands[selected].id) } }
            }
        }.padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
    }
}
