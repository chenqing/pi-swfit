#if os(macOS)
import AppKit
import Testing
@testable import PiUI

@MainActor
struct ComposerEditorTests {
    private func key(_ modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                        isARepeat: repeatKey, keyCode: 36)!
    }

    @Test func returnSubmitsButModifiedReturnInsertsNewline() {
        let editor = ComposerTextView()
        var sends = 0
        editor.submit = { sends += 1 }
        editor.string = "Draft"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.keyDown(with: key(.shift))
        #expect(editor.string == "Draft\n")
        #expect(sends == 0)
        editor.keyDown(with: key(.option))
        #expect(editor.string == "Draft\n\n")
        editor.keyDown(with: key())
        editor.keyDown(with: key(.command))
        #expect(sends == 2)
        editor.keyDown(with: key(repeatKey: true))
        #expect(sends == 2)
    }

    @Test func markedTextConfirmationDoesNotSubmit() {
        let editor = ComposerTextView()
        var sends = 0
        editor.submit = { sends += 1 }
        editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.keyDown(with: key())
        #expect(sends == 0)
    }

    @Test func multilineInsertionIsOnlyDraft() {
        let editor = ComposerTextView()
        var sends = 0
        editor.submit = { sends += 1 }
        editor.insertText("let n = 1\nprint(n)", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "let n = 1\nprint(n)")
        #expect(sends == 0)
    }
}
#endif
