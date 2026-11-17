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
    func applyMultiCaretOverwrite(_ insertion: String)
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

    /// Overwrite (OVR) typing. Session-only UI state: it lives on the shared
    /// text view, so it survives tab switches in this window but is not a
    /// preference and is not persisted per document. The status bar's INS/OVR
    /// field is the only toggle (no Insert key in v1; see KEYBINDINGS notes).
    var isOverwriteMode = false

    // MARK: - Symbol rendering
    //
    // View > Show Symbol toggles. All three are drawn in `draw(_:)` from the
    // laid-out glyphs inside the dirty rect, so they scroll, wrap, and zoom with
    // the text without an overlay view or a timer. The symbol colour is derived
    // from `textColor` (the theme foreground) at draw time.

    /// Draw a middle dot on every space and an arrow across every tab.
    private(set) var showsWhitespace = false
    /// Draw a boxed CR/LF/CRLF label at each line terminator.
    private(set) var showsEOL = false
    /// Draw dotted vertical guides at the tab stops of each indented line.
    private(set) var showsIndentGuide = false
    /// Tab-stop width used for indent guides. Mirrors `Preferences.tabSize`.
    private(set) var tabSize = 4

    /// Applies the Show Symbol preferences, coalescing the repaint into one
    /// invalidation when anything actually changed.
    func setSymbolVisibility(showWhitespace: Bool,
                             showEOL: Bool,
                             showIndentGuide: Bool,
                             tabSize: Int) {
        let clampedTab = max(1, tabSize)
        guard self.showsWhitespace != showWhitespace
                || self.showsEOL != showEOL
                || self.showsIndentGuide != showIndentGuide
                || self.tabSize != clampedTab else { return }
        self.showsWhitespace = showWhitespace
        self.showsEOL = showEOL
        self.showsIndentGuide = showIndentGuide
        self.tabSize = clampedTab
        needsDisplay = true
    }

    // MARK: - Token styles
    //
    // The five Search > Style commands paint persistent backgrounds. They are
    // temporary attributes with a dedicated key, not text-storage attributes,
    // because the syntax highlighter rewrites the visible band's attributes on
    // every keystroke and the FindBar clears every *background* temporary
    // attribute when it closes. A private key belongs to neither pipeline, and
    // the backgrounds are drawn in drawViewBackground(in:), below the glyphs and
    // below the FindBar's own background highlights.

    /// Temporary-attribute key carrying a style number (1...5).
    static let tokenStyleAttribute = NSAttributedString.Key("HexpadTokenStyle")

    private(set) var tokenStyleState = TokenStyleState()
    private var tokenStyleColors: [NSColor] = []

    /// Adopts `state` and repaints the styled ranges with the theme palette.
    ///
    /// The temporary attributes are rewritten over the current buffer's full
    /// length, so switching tabs cannot leave another document's ranges behind.
    func applyTokenStyles(_ state: TokenStyleState, theme: Theme) {
        tokenStyleState = state
        tokenStyleColors = TokenStylePalette.colors(for: theme)
        guard let layoutManager else { return }

        let length = (string as NSString).length
        if length > 0 {
            layoutManager.removeTemporaryAttribute(
                Self.tokenStyleAttribute,
                forCharacterRange: NSRange(location: 0, length: length)
            )
        }
        for entry in state.styledRanges {
            guard entry.range.location != NSNotFound, entry.range.length > 0 else { continue }
            let start = min(entry.range.location, length)
            let end = min(entry.range.location + entry.range.length, length)
            guard end > start else { continue }
            layoutManager.addTemporaryAttributes(
                [Self.tokenStyleAttribute: NSNumber(value: entry.style)],
                forCharacterRange: NSRange(location: start, length: end - start)
            )
        }
        needsDisplay = true
    }

    /// Paints the styled backgrounds before the glyphs are drawn.
    /// (NSTextView's drawViewBackgroundInRect: is Swift-renamed to drawBackground(in:).)
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawTokenStyleBackgrounds(in: rect)
    }

    private func drawTokenStyleBackgrounds(in dirtyRect: NSRect) {
        guard !tokenStyleState.isEmpty, !tokenStyleColors.isEmpty,
              let layoutManager, let textContainer else { return }

        let length = (string as NSString).length
        guard length > 0 else { return }

        let origin = textContainerOrigin
        let containerDirty = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: containerDirty,
                                                     in: textContainer)
        guard visibleGlyphs.length > 0 else { return }
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs,
                                                       actualGlyphRange: nil)
        let bufferRange = NSRange(location: 0, length: length)

        // Read the same temporary attributes the rest of the editor can inspect,
        // so the drawn layer can never disagree with the stored marks.
        var index = visibleChars.location
        while index < visibleChars.location + visibleChars.length {
            var effective = NSRange(location: index, length: 1)
            let value = layoutManager.temporaryAttribute(
                Self.tokenStyleAttribute,
                atCharacterIndex: index,
                effectiveRange: &effective
            )
            let effectiveLength = max(1, effective.length)
            if let number = value as? NSNumber {
                let style = number.intValue
                let clipped = NSIntersectionRange(effective, bufferRange)
                if clipped.length > 0,
                   style >= 1, style <= tokenStyleColors.count {
                    fillTokenStyleBackground(color: tokenStyleColors[style - 1],
                                             for: clipped)
                }
            }
            index += effectiveLength
        }
    }

    private func fillTokenStyleBackground(color: NSColor, for characterRange: NSRange) {
        guard let layoutManager, let textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange,
                                                  actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        let origin = textContainerOrigin
        color.setFill()
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }

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
        let insertion: String
        if let attributed = string as? NSAttributedString {
            insertion = attributed.string
        } else if let plain = string as? String {
            insertion = plain
        } else {
            insertion = "\(string)"
        }

        if isOverwriteMode, Self.isSingleTypedCharacter(insertion) {
            if let host, host.multiCaretState.count > 1 {
                host.applyMultiCaretOverwrite(insertion)
                return
            }
            if let overwrite = overwriteRange(forReplacementRange: replacementRange) {
                super.insertText(string, replacementRange: overwrite)
                return
            }
        }

        guard let host, host.multiCaretState.count > 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        guard !insertion.isEmpty else { return }
        host.applyMultiCaretInsertion(insertion)
    }

    /// Overwrite applies to one typed character. A paste, a tab or a newline
    /// goes through the normal insertion path instead of replacing text.
    private static func isSingleTypedCharacter(_ insertion: String) -> Bool {
        guard insertion.count == 1 else { return false }
        return !insertion.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    /// The range a single typed character should replace: the composed
    /// character under a zero-length caret, unless the caret sits on a line
    /// ending or at the end of the buffer (typing there appends).
    ///
    /// Returns `nil` when the normal insertion path should run, which also
    /// covers typing over a non-empty selection.
    private func overwriteRange(forReplacementRange replacementRange: NSRange) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let selection = selectedRange
        let range: NSRange
        if replacementRange.location == NSNotFound {
            range = selection
        } else {
            // Only a plain caret qualifies: an explicit replacement range from
            // an input method must not swallow the character after it.
            guard replacementRange.length == 0, replacementRange == selection else {
                return nil
            }
            range = replacementRange
        }
        guard range.length == 0, range.location < storage.length else { return nil }

        let text = storage.string as NSString
        let unit = text.character(at: range.location)
        guard unit != 10, unit != 13 else { return nil }
        return text.rangeOfComposedCharacterSequence(at: range.location)
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
        drawAdditionalCarets()
        guard showsWhitespace || showsEOL || showsIndentGuide else { return }
        drawSymbols(in: dirtyRect)
    }

    private func drawAdditionalCarets() {
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

    // MARK: - Show Symbol rendering
    //
    // Symbols are drawn after the text in `draw(_:)`, in text-container
    // coordinates, from the glyphs the layout manager already laid out inside
    // the dirty rect. There is no overlay view to keep in scroll sync and no
    // per-keystroke document scan: the work is O(visible glyphs).

    /// Paints space dots, tab arrows, end-of-line labels, and indent guides for
    /// the glyphs intersecting `dirtyRect` (view coordinates).
    private func drawSymbols(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer, let storage = textStorage else { return }
        let text = storage.string as NSString
        guard text.length > 0 else { return }

        let origin = textContainerOrigin
        let containerDirty = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerDirty,
                                                  in: textContainer)
        guard glyphRange.length > 0 else { return }

        let foreground = textColor ?? NSColor.secondaryLabelColor
        let whitespaceColor = foreground.withAlphaComponent(0.35)
        let guideColor = foreground.withAlphaComponent(0.22)
        let eolColor = foreground.withAlphaComponent(0.6)
        let bodyFont = font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize,
                                                           weight: .regular)
        let spaceAdvance = (" " as NSString)
            .size(withAttributes: [.font: bodyFont]).width
        let eolFont = NSFont.monospacedSystemFont(ofSize: max(8, bodyFont.pointSize * 0.7),
                                                  weight: .regular)

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [weak self] lineRect, usedRect, _, lineGlyphRange, _ in
            guard let self else { return }

            let lineCharRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange,
                                                            actualGlyphRange: nil)
            guard lineCharRange.length > 0 else { return }
            let ending = self.lineEnding(in: text, for: lineCharRange)
            let content = NSRange(location: lineCharRange.location,
                                  length: ending?.contentLength ?? lineCharRange.length)
            let lineMidY = origin.y + lineRect.midY

            if self.showsWhitespace, content.length > 0 {
                for index in content.location..<content.upperBound {
                    let unit = text.character(at: index)
                    guard unit == 0x20 || unit == 0x09 else { continue } // space / tab
                    let glyph = layoutManager.glyphIndexForCharacter(at: index)
                    guard glyph < layoutManager.numberOfGlyphs else { continue }
                    let startX = origin.x + layoutManager.location(forGlyphAt: glyph).x

                    if unit == 0x20 {
                        let diameter: CGFloat = 2
                        let dot = NSRect(x: startX + (spaceAdvance - diameter) / 2,
                                         y: lineMidY - diameter / 2,
                                         width: diameter,
                                         height: diameter)
                        guard dot.intersects(dirtyRect) else { continue }
                        whitespaceColor.setFill()
                        NSBezierPath(ovalIn: dot).fill()
                        continue
                    }

                    let nextX: CGFloat
                    if index + 1 < content.upperBound {
                        let nextGlyph = layoutManager.glyphIndexForCharacter(at: index + 1)
                        nextX = origin.x + layoutManager.location(forGlyphAt: nextGlyph).x
                    } else {
                        nextX = origin.x + usedRect.maxX
                    }
                    // A tab at a soft-wrap boundary reports the next visual
                    // line's origin; fall back to the used width instead.
                    let endX = nextX > startX ? nextX : origin.x + usedRect.maxX
                    guard NSRect(x: startX, y: lineMidY - 4,
                                 width: max(0, endX - startX), height: 8)
                        .intersects(dirtyRect) else { continue }
                    self.drawTabArrow(fromX: startX, toX: endX,
                                      midY: lineMidY, color: whitespaceColor)
                }
            }

            if self.showsIndentGuide, content.length > 0 {
                var leadingLength = 0
                while leadingLength < content.length {
                    let unit = text.character(at: content.location + leadingLength)
                    guard unit == 0x20 || unit == 0x09 else { break }
                    leadingLength += 1
                }
                if leadingLength > 0 {
                    let leadingRange = NSRange(location: content.location,
                                               length: leadingLength)
                    let leading = text.substring(with: leadingRange)
                    let runs = WhitespaceGeometry.columnRuns(
                        forLeadingWhitespace: leading, tabSize: self.tabSize)
                    let columns = WhitespaceGeometry.guideColumns(
                        forLeadingWhitespace: leading, tabSize: self.tabSize)
                    for column in columns {
                        guard let x = self.guideX(forColumn: column,
                                                  runs: runs,
                                                  leadingRange: leadingRange,
                                                  contentUpperBound: content.upperBound,
                                                  usedMaxX: usedRect.maxX,
                                                  origin: origin,
                                                  layoutManager: layoutManager) else { continue }
                        guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX + 1 else { continue }
                        let guide = NSBezierPath()
                        guide.move(to: NSPoint(x: x, y: origin.y + lineRect.minY + 1))
                        guide.line(to: NSPoint(x: x, y: origin.y + lineRect.maxY - 1))
                        guide.lineWidth = 1
                        guide.setLineDash([1, 2], count: 2, phase: 0)
                        guideColor.setStroke()
                        guide.stroke()
                    }
                }
            }

            if self.showsEOL, let ending {
                let label = NSAttributedString(
                    string: ending.label,
                    attributes: [.font: eolFont, .foregroundColor: eolColor])
                let labelSize = label.size()
                let box = NSRect(x: origin.x + usedRect.maxX + 2,
                                 y: lineMidY - 7,
                                 width: labelSize.width + 6,
                                 height: max(12, labelSize.height + 2))
                guard box.intersects(dirtyRect) else { return }
                let border = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
                border.lineWidth = 1
                eolColor.setStroke()
                border.stroke()
                label.draw(at: NSPoint(x: box.minX + 3,
                                       y: box.midY - labelSize.height / 2))
            }
        }
    }

    /// The terminator ending `lineRange`, if this laid-out fragment ends a
    /// logical line. TextKit includes the newline in the fragment's character
    /// range; some layouts leave it just past the range, so both cases are
    /// handled.
    private func lineEnding(in text: NSString,
                            for lineRange: NSRange) -> (label: String, contentLength: Int)? {
        if lineRange.length > 0 {
            let last = text.character(at: lineRange.upperBound - 1)
            if last == 10 { // \n
                if lineRange.length >= 2,
                   text.character(at: lineRange.upperBound - 2) == 13 {
                    return (EOLDetective.crlf, lineRange.length - 2)
                }
                return (EOLDetective.lf, lineRange.length - 1)
            }
            if last == 13 {
                if lineRange.upperBound < text.length,
                   text.character(at: lineRange.upperBound) == 10 {
                    return (EOLDetective.crlf, lineRange.length - 1)
                }
                return (EOLDetective.cr, lineRange.length - 1)
            }
        }

        let next = lineRange.upperBound
        guard next < text.length else { return nil }
        let following = text.character(at: next)
        if following == 13 {
            if next + 1 < text.length, text.character(at: next + 1) == 10 {
                return (EOLDetective.crlf, lineRange.length)
            }
            return (EOLDetective.cr, lineRange.length)
        }
        if following == 10 {
            return (EOLDetective.lf, lineRange.length)
        }
        return nil
    }

    /// X coordinate (view space) of indent guide `column`, interpolated inside
    /// a tab's actual laid-out width so guides align with rendered glyphs.
    private func guideX(forColumn column: Int,
                        runs: [WhitespaceGeometry.ColumnRun],
                        leadingRange: NSRange,
                        contentUpperBound: Int,
                        usedMaxX: CGFloat,
                        origin: NSPoint,
                        layoutManager: NSLayoutManager) -> CGFloat? {
        guard let runIndex = runs.firstIndex(where: {
            column > $0.startColumn && column <= $0.endColumn
        }) else { return nil }

        let characterIndex = leadingRange.location + runIndex
        let glyph = layoutManager.glyphIndexForCharacter(at: characterIndex)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let startX = layoutManager.location(forGlyphAt: glyph).x

        let endX: CGFloat
        let nextIndex = characterIndex + 1
        if nextIndex < contentUpperBound {
            let nextGlyph = layoutManager.glyphIndexForCharacter(at: nextIndex)
            endX = nextGlyph < layoutManager.numberOfGlyphs
                ? layoutManager.location(forGlyphAt: nextGlyph).x
                : usedMaxX
        } else {
            endX = usedMaxX
        }

        let run = runs[runIndex]
        let span = CGFloat(max(run.endColumn - run.startColumn, 1))
        let progress = min(max(CGFloat(column - run.startColumn) / span, 0), 1)
        return origin.x + startX + (endX - startX) * progress
    }

    /// A thin horizontal arrow spanning one tab, Notepad++'s tab glyph.
    private func drawTabArrow(fromX: CGFloat, toX: CGFloat, midY: CGFloat,
                              color: NSColor) {
        let start = fromX + 1
        let end = max(start + 1, toX - 1)
        let head = min(3, max(1, (end - start) / 2))

        let path = NSBezierPath()
        path.move(to: NSPoint(x: start, y: midY))
        path.line(to: NSPoint(x: end, y: midY))
        path.move(to: NSPoint(x: end - head, y: midY - head))
        path.line(to: NSPoint(x: end, y: midY))
        path.line(to: NSPoint(x: end - head, y: midY + head))
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }
}
