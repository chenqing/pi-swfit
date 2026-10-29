import SwiftUI
import PiHost

struct SlashCommandMenu: View {
    let commands: [CommandDescriptor]
    let selected: Int
    let choose: (CommandDescriptor) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Commands").fontWeight(.medium)
                Spacer()
                Text("↑↓ select · Tab complete · Esc close")
            }.accessibilityElement(children: .combine).font(.system(size: 11)).foregroundStyle(ChatPalette.secondaryText).padding(.horizontal, 10).padding(.vertical, 5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            Button { choose(command) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("/" + command.name).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                        Text(command.source.rawValue).font(.system(size: 11)).foregroundStyle(ChatPalette.secondaryText)
                                    }.frame(width: 150, alignment: .leading)
                                    Text(command.summary).font(.system(size: 12)).foregroundStyle(ChatPalette.secondaryText).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(index == selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(command.id).help(command.location ?? command.summary)
                                .accessibilityLabel("/\(command.name), \(command.summary)")
                                .accessibilityValue(index == selected ? "Selected" : "")
                        }
                    }
                }.frame(height: CGFloat(min(commands.count, 5)) * 46)
                    .onChange(of: selected) { if commands.indices.contains(selected) { proxy.scrollTo(commands[selected].id) } }
            }
        }.onChange(of: selected) {
            if commands.indices.contains(selected) {
                let command = commands[selected]
                ChatAccessibility.announce("/" + command.name + ". " + command.summary)
            }
        }.padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
    }
}
