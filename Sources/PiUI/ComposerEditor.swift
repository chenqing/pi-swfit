#if os(macOS)
import AppKit
import SwiftUI

/// A plain-text editor with chat keyboard semantics and native input-method handling.
struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var height: CGFloat
    var identity = ""
    var focusRequest = 0
    var commandKey: ((UInt16) -> Bool)? = nil
    let submit: () -> Void

    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView()
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 14),
                                   .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        editor.setAccessibilityLabel("Message")
        editor.setAccessibilityHelp("Return to send. Shift-Return for a new line.")
        editor.delegate = context.coordinator
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        context.coordinator.scroll = scroll
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.submit = submit
        editor.commandKey = commandKey
        editor.focusChanged = { [weak coordinator] value in
            DispatchQueue.main.async { coordinator?.parent.focused = value }
        }
        editor.synchronize(text, identity: identity)
        coordinator.requestFocus(focused, editor: editor)
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
        coordinator.measure()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        weak var scroll: ComposerScrollView?
        private var lastRequestedFocus = false
        var lastFocusRequest = 0
        init(_ parent: ComposerEditor) { self.parent = parent }
        func requestFocus(_ requested: Bool, editor: ComposerTextView) {
            // A layout/state refresh must not reclaim focus from search or another field
            // while the asynchronous resign callback is still catching up.
            guard requested != lastRequestedFocus else { return }
            lastRequestedFocus = requested
            if requested, let window = editor.window, window.firstResponder !== editor {
                window.makeFirstResponder(editor)
            }
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ComposerTextView, !editor.isSynchronizing else { return }
            if parent.text != editor.string { parent.text = editor.string }
            measure()
        }
        func measure() {
            guard let scroll, let editor = scroll.documentView as? NSTextView,
                  let container = editor.textContainer, let layout = editor.layoutManager,
                  scroll.contentSize.width > 0 else { return }
            container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let wanted = max(28, ceil(layout.usedRect(for: container).height) + 8)
            editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, wanted)))
            let height = min(168, wanted)
            if parent.height != height {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.parent.height != height else { return }
                    self.parent.height = height
                }
            }
        }
    }
}

final class ComposerScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

final class ComposerTextView: NSTextView {
    private let draftUndoManager = UndoManager()
    override var undoManager: UndoManager? { draftUndoManager }
    private var draftIdentity: String?
    private(set) var isSynchronizing = false
    /// Only a conversation switch clears undo. Same-draft insertions use AppKit editing.
    func synchronize(_ text: String, identity: String) {
        isSynchronizing = true; defer { isSynchronizing = false }
        if draftIdentity != identity {
            if hasMarkedText() { unmarkText() }
            draftIdentity = identity
            string = text
            setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            draftUndoManager.removeAllActions()
        } else if string != text, !hasMarkedText() {
            breakUndoCoalescing()
            // SwiftUI/AX button actions can share an AppKit event group. Give each
            // programmatic edit its own group so Send → Re-edit never cancels out.
            while draftUndoManager.groupingLevel > 0 { draftUndoManager.endUndoGrouping() }
            let groupsByEvent = draftUndoManager.groupsByEvent
            draftUndoManager.groupsByEvent = false
            draftUndoManager.beginUndoGrouping()
            let range = NSRange(location: 0, length: (string as NSString).length)
            if shouldChangeText(in: range, replacementString: text) {
                textStorage?.replaceCharacters(in: range, with: text)
                didChangeText()
                setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
            draftUndoManager.endUndoGrouping()
            draftUndoManager.groupsByEvent = groupsByEvent
            breakUndoCoalescing()
        }
    }
    @objc func undo(_ sender: Any?) { draftUndoManager.undo() }
    @objc func redo(_ sender: Any?) { draftUndoManager.redo() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return draftUndoManager.canUndo }
        if item.action == #selector(redo(_:)) { return draftUndoManager.canRedo }
        return super.validateUserInterfaceItem(item)
    }
    var commandKey: ((UInt16) -> Bool)?
    var submit: (() -> Void)?
    var focusChanged: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged?(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged?(false) }
        return result
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty,
           commandKey?(event.keyCode) == true { return }
        // Let AppKit consume Return to confirm Chinese/Japanese composition first.
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            if event.modifierFlags.intersection([.shift, .option, .control]).isEmpty {
                if !event.isARepeat { submit?() }
                return
            }
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }
}
#endif
