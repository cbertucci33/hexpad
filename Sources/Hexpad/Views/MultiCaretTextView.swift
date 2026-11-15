import AppKit
import HexpadKit

/// Events the text view forwards to the editor container that owns the
/// authoritative multi-caret state.
///
/// The text view deliberately keeps no caret list of its own: every gesture and
/// edit call mutates `EditorContainer.multiCaretState`, and rendering reads that
/// same state. This keeps NSTextView's single selection and the extra carets
/// from becoming two competing sources of truth.
protocol MultiCaretTextViewHost: AnyObject {
    var multiCaretState: MultiCaretState { get }

    func placeAdditionalCaret(atCharacterIndex index: Int)
    func beginColumnSelection(atCharacterIndex index: Int)
    func updateColumnSelection(toCharacterIndex index: Int)
    func endColumnSelection()
    func collapseMultiCaret()

    func applyMultiCaretInsertion(_ insertion: String)
    func applyMultiCaretDeletion(forward: Bool)
}

/// `NSTextView` with the multi-caret gestures and overlays used by the editor.
///
/// Extra carets are drawn in `draw(_:)` in text-container coordinates, so they
/// scroll and zoom with the text without a separate overlay view or a timer.
final class MultiCaretTextView: NSTextView {

    weak var host: MultiCaretTextViewHost?

    /// Whether the current mouse gesture started as an Option-drag column
    /// selection. The caret count cannot stand in for this: a zero-width column
    /// drag legitimately has only one caret at its start.
    private var isColumnSelecting = false

    // MARK: - Mouse gestures

    override func mouseDown(with event: NSEvent) {
        guard let host else {
            super.mouseDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)

        // Option-drag is the macOS column-selection gesture. Handle it before
        // the text view's own selection tracking so the drag can build a
        // rectangle instead of a linear selection.
        if flags.contains(.option) {
            window?.makeFirstResponder(self)
            let index = characterIndexForInsertion(at: point)
            isColumnSelecting = true
            host.beginColumnSelection(atCharacterIndex: index)
            return
        }

        // Cmd-click is the additional-caret gesture. On macOS the platform
        // already owns Option for column selection, so Cmd is the conflict-free
        // conventional choice.
        if flags.contains(.command) {
            window?.makeFirstResponder(self)
            host.placeAdditionalCaret(atCharacterIndex: characterIndexForInsertion(at: point))
            return
        }

        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host, isColumnSelecting else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        host.updateColumnSelection(toCharacterIndex: characterIndexForInsertion(at: point))
    }

    override func mouseUp(with event: NSEvent) {
        let wasColumnSelecting = isColumnSelecting
        isColumnSelecting = false
        host?.endColumnSelection()
        if !wasColumnSelecting {
            super.mouseUp(with: event)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Esc collapses the extra carets before any completion/cancel handling.
        if event.keyCode == 53, let host, host.multiCaretState.count > 1 {
            host.collapseMultiCaret()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let host, host.multiCaretState.count > 1 {
            host.collapseMultiCaret()
            return
        }
        super.cancelOperation(sender)
    }

    // MARK: - Editing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let host, host.multiCaretState.count > 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let insertion: String
        if let attributed = string as? NSAttributedString {
            insertion = attributed.string
        } else if let plain = string as? String {
            insertion = plain
        } else {
            insertion = "\(string)"
        }
        guard !insertion.isEmpty else { return }
        host.applyMultiCaretInsertion(insertion)
    }

    override func deleteBackward(_ sender: Any?) {
        guard let host, host.multiCaretState.count > 1 else {
            super.deleteBackward(sender)
            return
        }
        host.applyMultiCaretDeletion(forward: false)
    }

    override func deleteForward(_ sender: Any?) {
        guard let host, host.multiCaretState.count > 1 else {
            super.deleteForward(sender)
            return
        }
        host.applyMultiCaretDeletion(forward: true)
    }

    override func paste(_ sender: Any?) {
        guard let host, host.multiCaretState.count > 1 else {
            super.paste(sender)
            return
        }
        guard let string = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        host.applyMultiCaretInsertion(string)
    }

    // MARK: - Extra-caret rendering

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let host else { return }

        let state = host.multiCaretState
        guard state.count > 1 else { return }

        let selectionColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.22)
        let caretColor = insertionPointColor ?? .textColor

        for caret in state.carets.dropFirst() {
            if caret.length > 0 {
                selectionColor.setFill()
                for rect in selectionRects(for: caret) {
                    rect.fill()
                }
            }
            guard let rect = caretRect(at: caret.location) else { continue }
            caretColor.setFill()
            rect.fill()
        }
    }

    /// Rect for the insertion point at `characterIndex`, in view coordinates.
    private func caretRect(at characterIndex: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }

        let length = (string as NSString).length
        let index = min(max(0, characterIndex), length)
        let origin = textContainerOrigin
        let caretWidth: CGFloat = 2

        // End of document: TextKit exposes an extra line fragment for the empty
        // line after a trailing newline and for an empty document.
        if index >= length,
           let extraContainer = layoutManager.extraLineFragmentTextContainer,
           extraContainer === textContainer {
            let fragment = layoutManager.extraLineFragmentRect
            return NSRect(x: origin.x + fragment.minX,
                          y: origin.y + fragment.minY,
                          width: caretWidth,
                          height: max(fragment.height, 1))
        }

        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else {
            let height = (font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
                .boundingRectForFont.height
            return NSRect(x: origin.x + textContainer.lineFragmentPadding,
                          y: origin.y,
                          width: caretWidth,
                          height: max(height, 1))
        }

        let glyphIndex = index < length
            ? layoutManager.glyphIndexForCharacter(at: index)
            : glyphCount - 1
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                      effectiveRange: nil)
        let x = index < length
            ? layoutManager.location(forGlyphAt: glyphIndex).x
            : layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex,
                                                 effectiveRange: nil).maxX

        return NSRect(x: origin.x + x,
                      y: origin.y + fragment.minY,
                      width: caretWidth,
                      height: max(fragment.height, 1))
    }

    /// Rects covering a non-primary selection, in view coordinates.
    private func selectionRects(for characterRange: NSRange) -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }

        let length = (string as NSString).length
        let location = min(max(0, characterRange.location), length)
        let safeRange = NSRange(location: location,
                                length: min(max(0, characterRange.length), length - location))
        guard safeRange.length > 0 else { return [] }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange,
                                                  actualCharacterRange: nil)
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }
}
