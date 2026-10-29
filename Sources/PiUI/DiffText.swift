import SwiftUI

public struct DiffText: View {
    let diff: String
    public init(diff: String) { self.diff = diff }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .foregroundStyle(line.hasPrefix("+") && !line.hasPrefix("+++") ? Color.green : line.hasPrefix("-") && !line.hasPrefix("---") ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
    }
}
