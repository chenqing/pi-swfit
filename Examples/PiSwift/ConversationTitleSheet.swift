#if os(macOS)
import SwiftUI

struct ConversationTitleSheet: View {
    @State var title: String
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename conversation").font(.headline)
            TextField("Conversation title", text: $title).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel("Conversation title")
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do { try save(title); dismiss() }
                    catch { self.error = String(describing: error) }
                }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 380).onAppear { focused = true }
    }
}
#endif
