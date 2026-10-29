#if os(macOS)
import AppKit
import Testing
import SwiftUI
@testable import PiUI

@MainActor
struct ComposerEditorTests {
    @Test func textSizePreservesDraftSelectionUndoAndMarkedText() throws {
        let editor = ComposerTextView(); editor.allowsUndo = true
        editor.synchronize("Original 中文", identity: "first")
        editor.synchronize("Edited 中文", identity: "first")
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        editor.applyTextSize(22)
        #expect(editor.font?.pointSize == 21)
        #expect(editor.string == "Edited 中文")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 3))
        editor.undo(nil)
        #expect(editor.string == "Original 中文")
        editor.applyTextSize(22)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        editor.applyTextSize(13)
        #expect(editor.font?.pointSize == 21)
        #expect(editor.markedRange() == marked)
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.applyTextSize(13)
        #expect(editor.font?.pointSize == 12)
        #expect(editor.string == "Original 中文你")
    }

    @Test func tabMovesFocusButCommandCompletionKeepsIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: false)
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let next = NSTextView(frame: NSRect(x: 0, y: 100, width: 200, height: 80))
        window.contentView?.addSubview(editor); window.contentView?.addSubview(next)
        editor.nextKeyView = next; next.nextKeyView = editor
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        window.makeFirstResponder(editor)
        editor.keyDown(with: tab)
        #expect(window.firstResponder === next)
        #expect(editor.string.isEmpty)
        window.makeFirstResponder(editor)
        editor.commandKey = { $0 == 48 }
        editor.keyDown(with: tab)
        #expect(window.firstResponder === editor)
        #expect(editor.string.isEmpty)
    }

    @Test func invalidTextSizesHaveSafeReadableBounds() {
        #expect(ChatTextSize.clamped(.nan) == 15)
        #expect(ChatTextSize.clamped(.infinity) == 15)
        #expect(ChatTextSize.clamped(-1) == 13)
        #expect(ChatTextSize.clamped(1000) == 22)
        #expect(ChatTextSize.clamped(18) == 18)
    }

    @Test func placeholderTracksCompositionBeforeDraftBindingChanges() {
        let editor = ComposerTextView()
        editor.synchronize("", identity: "first")
        #expect(editor.showsPlaceholder)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!editor.showsPlaceholder)
        // A refresh with the still-empty model must not restore the hint.
        editor.synchronize("", identity: "first")
        #expect(!editor.showsPlaceholder)
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "你")
        #expect(!editor.hasMarkedText())
        #expect(!editor.showsPlaceholder)
        editor.synchronize("", identity: "first")
        #expect(editor.showsPlaceholder)
        // Use a fresh input event context for cancellation; synchronize closes
        // the previous native undo event when it clears the draft above.
        let cancelled = ComposerTextView()
        cancelled.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        cancelled.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        cancelled.unmarkText()
        #expect(cancelled.showsPlaceholder)
        editor.synchronize("Restored draft", identity: "second")
        #expect(!editor.showsPlaceholder)
    }

    @Test func commandNavigationDoesNotHijackMarkedTextOrShiftReturn() throws {
        let editor = ComposerTextView()
        var keys: [UInt16] = []
        editor.commandKey = { keys.append($0); return true }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        editor.keyDown(with: try key(125))
        #expect(keys == [125])
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: try key(125))
        #expect(keys == [125])
        editor.unmarkText()
        editor.keyDown(with: try key(36, flags: .shift))
        #expect(keys == [125])
    }

    @Test func refreshingFocusedEditorDoesNotStealSearchFocus() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: false)
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let other = ComposerTextView(frame: NSRect(x: 0, y: 100, width: 200, height: 80))
        window.contentView?.addSubview(editor); window.contentView?.addSubview(other)
        let parent = ComposerEditor(text: .constant(""), focused: .constant(true), height: .constant(28), submit: {})
        let coordinator = ComposerEditor.Coordinator(parent)
        coordinator.requestFocus(true, editor: editor)
        #expect(window.firstResponder === editor)
        window.makeFirstResponder(other)
        coordinator.requestFocus(true, editor: editor)
        #expect(window.firstResponder === other)
        coordinator.requestFocus(false, editor: editor)
        coordinator.requestFocus(true, editor: editor)
        #expect(window.firstResponder === editor)
    }
    @Test func programmaticDraftChangesUndoAndRedoWithoutCrossingSessions() throws {
        let editor = ComposerTextView()
        editor.allowsUndo = true
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        editor.synchronize("Original 中文", identity: "first")
        editor.synchronize("Original 中文\n\nInserted file", identity: "first")
        #expect(undo.canUndo)
        let undoItem = NSMenuItem(title: "Undo", action: #selector(ComposerTextView.undo(_:)), keyEquivalent: "z")
        #expect(editor.validateUserInterfaceItem(undoItem))
        editor.undo(nil)
        #expect(editor.string == "Original 中文")
        editor.redo(nil)
        #expect(editor.string == "Original 中文\n\nInserted file")
        editor.synchronize("Different draft", identity: "second")
        #expect(!undo.canUndo)
        #expect(!editor.validateUserInterfaceItem(undoItem))
        #expect(!undo.canRedo)
        #expect(editor.string == "Different draft")
    }
    @Test func sendThenReeditAreSeparateUndoActionsEvenWithinOneEvent() {
        let editor = ComposerTextView(); editor.allowsUndo = true
        editor.synchronize("Request", identity: "first")
        editor.synchronize("", identity: "first")
        editor.synchronize("Request", identity: "first")
        editor.undo(nil)
        #expect(editor.string == "")
        editor.undo(nil)
        #expect(editor.string == "Request")
    }
    @Test func sameSessionSynchronizationDoesNotReplaceMarkedText() {
        let editor = ComposerTextView()
        editor.synchronize("", identity: "first")
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.synchronize("External text", identity: "first")
        #expect(editor.hasMarkedText())
        #expect(editor.string == "中文")
        editor.synchronize("Another conversation", identity: "second")
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "Another conversation")
    }
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
