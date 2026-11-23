import AppKit
import HexpadKit

class StatusBar: NSView {
    
    private var positionLabel: NSTextField?
    private var modeLabel: ClickableStatusLabel?
    private var selectionLabel: NSTextField?
    private var eolLabel: NSTextField?
    private var encodingLabel: NSTextField?
    private var languageLabel: NSTextField?
    private var lengthLabel: NSTextField?
    private var linesLabel: NSTextField?

    /// Fired when the user clicks the INS/OVR field. The window controller
    /// flips overwrite mode on the focused editor and refreshes this bar.
    var onToggleOverwriteMode: (() -> Void)?

    /// A line index plus the identity of the text it was built from.
    ///
    /// `storageID`/`documentID` prevent a tab switch from reusing another
    /// buffer's offsets, and the pending-edit list below makes the cache valid
    /// exactly while the (document, text) pair is unchanged.
    private struct LineIndexCache {
        let documentID: UUID?
        let storageID: ObjectIdentifier
        let index: LineIndex
    }

    private var lineIndexCache: LineIndexCache?

    /// Character edit waiting to be spliced into the cached index. Usually at
    /// most one (updateStatusBar runs per keystroke); more than one between
    /// updates falls back to a full scan rather than guessing intermediate text.
    private struct PendingTextEdit {
        let range: NSRange
        let changeInLength: Int
    }
    private var pendingEdits: [PendingTextEdit] = []

    /// The storage the edit observer is currently following. Set on every
    /// `update` so edits to a previously shown tab cannot invalidate the
    /// current tab's cache.
    private var observedStorageID: ObjectIdentifier?

    private var editObserver: NSObjectProtocol?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshChromeColors()
        setupUI()
        startEditObservation()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Re-resolves the strip's background and separator for the current
    /// appearance. Both layers store CGColors, which freeze the resolved
    /// appearance, so a light/dark switch used to leave the status strip black.
    func refreshChromeColors() {
        layer?.backgroundColor = ChromeColor.cgColor(.controlBackgroundColor,
                                                     for: effectiveAppearance)
        separatorView?.layer?.backgroundColor = ChromeColor.cgColor(.separatorColor,
                                                                   for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
        needsDisplay = true
    }

    deinit {
        if let editObserver {
            NotificationCenter.default.removeObserver(editObserver)
        }
    }

    /// Records character edits on the observed buffer so the cached index can
    /// be spliced instead of rebuilt. Typing, undo, find/replace, line
    /// operations and reloads all mutate the document's single `NSTextStorage`,
    /// so this one notification covers every path that can move a line start
    /// (the container already relies on the same notification for
    /// fold/bookmark remapping).
    private func startEditObservation() {
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let storage = notification.object as? NSTextStorage,
                  let observed = self.observedStorageID,
                  ObjectIdentifier(storage) == observed,
                  storage.editedMask.contains(.editedCharacters) else { return }
            self.pendingEdits.append(PendingTextEdit(range: storage.editedRange,
                                                     changeInLength: storage.changeInLength))
            // Bounded: two coalesced edits already mean a full rebuild is
            // cheaper and safer than replaying imaginary intermediate text.
            if self.pendingEdits.count > 2 {
                self.pendingEdits.removeFirst(self.pendingEdits.count - 2)
            }
        }
    }
    
    private func setupUI() {
        let font = NSFont.systemFont(ofSize: 11)
        let height = bounds.height
        
        let pos = NSTextField(labelWithString: "Ln 1, Col 1")
        pos.font = font
        pos.frame = NSRect(x: 8, y: (height - 14) / 2, width: 120, height: 14)
        pos.setAccessibilityLabel("Cursor position")
        pos.setAccessibilityValue(pos.stringValue)
        addSubview(pos)
        positionLabel = pos
        
        // The mode indicator is the bar's only interactive field: a click
        // toggles overwrite typing for the focused editor (Notepad++ parity).
        let mode = ClickableStatusLabel(labelWithString: "INS")
        mode.font = font
        mode.frame = NSRect(x: 136, y: (height - 14) / 2, width: 34, height: 14)
        mode.onClick = { [weak self] in self?.onToggleOverwriteMode?() }
        mode.setAccessibilityLabel("Typing mode")
        mode.setAccessibilityRole(.button)
        mode.setAccessibilityValue(mode.stringValue)
        addSubview(mode)
        modeLabel = mode
        
        let sel = NSTextField(labelWithString: "0 selected")
        sel.font = font
        sel.frame = NSRect(x: 178, y: (height - 14) / 2, width: 100, height: 14)
        sel.setAccessibilityLabel("Selection")
        sel.setAccessibilityValue(sel.stringValue)
        addSubview(sel)
        selectionLabel = sel
        
        let eol = NSTextField(labelWithString: "LF")
        eol.font = font
        eol.frame = NSRect(x: 286, y: (height - 14) / 2, width: 40, height: 14)
        eol.setAccessibilityLabel("End of line")
        eol.setAccessibilityValue(eol.stringValue)
        addSubview(eol)
        eolLabel = eol
        
        let enc = NSTextField(labelWithString: "UTF-8")
        enc.font = font
        enc.frame = NSRect(x: 334, y: (height - 14) / 2, width: 70, height: 14)
        enc.setAccessibilityLabel("Encoding")
        enc.setAccessibilityValue(enc.stringValue)
        addSubview(enc)
        encodingLabel = enc
        
        let lang = NSTextField(labelWithString: "Plain Text")
        lang.font = font
        lang.frame = NSRect(x: 412, y: (height - 14) / 2, width: 100, height: 14)
        lang.setAccessibilityLabel("Language")
        lang.setAccessibilityValue(lang.stringValue)
        addSubview(lang)
        languageLabel = lang

        // Notepad++ shows length and lines as separate counters; the bar has
        // room at the 800pt minimum window width, so they stay separate.
        let length = NSTextField(labelWithString: "length : 0")
        length.font = font
        length.frame = NSRect(x: 520, y: (height - 14) / 2, width: 110, height: 14)
        length.setAccessibilityLabel("Length")
        length.setAccessibilityValue(length.stringValue)
        addSubview(length)
        lengthLabel = length

        let lines = NSTextField(labelWithString: "lines : 1")
        lines.font = font
        lines.frame = NSRect(x: 638, y: (height - 14) / 2, width: 80, height: 14)
        lines.setAccessibilityLabel("Lines")
        lines.setAccessibilityValue(lines.stringValue)
        addSubview(lines)
        linesLabel = lines

        let separator = NSView(frame: .zero)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = ChromeColor.cgColor(.separatorColor,
                                                              for: effectiveAppearance)
        separator.autoresizingMask = [.width, .minYMargin]
        separatorView = separator
        addSubview(separator)
    }

    private var separatorView: NSView?

    /// Labels are laid out here, not in setupUI: the bar is created with a
    /// zero-height frame and StatusBar never relaid out, so every label used
    /// to sit at y=-7 (half below the bar) with a zero-width separator.
    override func layout() {
        super.layout()
        let h = bounds.height
        let labelHeight: CGFloat = 14
        let y = max(0, (h - labelHeight) / 2)
        let xs: [(CGFloat, CGFloat)] = [
            (8, 120),   // Ln/Col
            (136, 34),  // INS/OVR
            (178, 100), // selection
            (286, 40),  // EOL
            (334, 70),  // encoding
            (412, 100), // language
            (520, 110), // length
            (638, 80)   // lines
        ]
        let labels: [NSTextField?] = [positionLabel, modeLabel, selectionLabel, eolLabel,
                                      encodingLabel, languageLabel, lengthLabel, linesLabel]
        for (label, geo) in zip(labels, xs) {
            label?.frame = NSRect(x: geo.0, y: y, width: geo.1, height: labelHeight)
        }
        separatorView?.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
    }
    
    func update(with doc: DocumentModel?, textView: NSTextView?, lineIndex: LineIndex? = nil) {
        guard let textView = textView else { return }
        
        let selRange = textView.selectedRange
        // Line math is O(log lines) once an index is available: a caller that
        // already owns one can pass it, otherwise the status bar reuses its own
        // cache and only re-indexes when the text has actually changed. This
        // replaces the two full-document scans (logicalLine + firstCharIndex)
        // that used to run on every caret move.
        let index = lineIndex ?? cachedLineIndex(for: doc, textView: textView)
        let line: Int
        let firstCharIndex: Int
        if let index {
            // One line lookup, then one start lookup for that line's column.
            line = index.line(of: selRange.location)
            firstCharIndex = index.firstCharIndex(of: line)
        } else {
            // No text storage to index (not a normal NSTextView): keep the
            // original GutterGeometry full-scan path unchanged.
            let text = textView.string
            line = GutterGeometry.logicalLine(of: selRange.location, in: text)
            firstCharIndex = GutterGeometry.firstCharIndex(of: line, in: text)
        }
        let col = selRange.location - firstCharIndex + 1
        positionLabel?.stringValue = "Ln \(line), Col \(col)"

        // Overwrite mode lives on the text view (shared by every tab in this
        // window), so the field always mirrors the editor rather than keeping
        // a second copy of the flag here.
        if let multiCaret = textView as? MultiCaretTextView {
            setOverwriteMode(multiCaret.isOverwriteMode)
        }

        // UTF-16 length matches the selection count above. Reading the storage
        // length avoids copying the buffer on every caret move; the line count
        // comes from the cached index, so neither counter adds a document scan.
        let length = textView.textStorage?.length ?? (textView.string as NSString).length
        lengthLabel?.stringValue = "length : \(length)"
        let lineCount = index?.count ?? GutterGeometry.lineCount(in: textView.string)
        linesLabel?.stringValue = "lines : \(lineCount)"
        
        if selRange.length > 0 {
            selectionLabel?.stringValue = "\(selRange.length) selected"
        } else {
            selectionLabel?.stringValue = "0 selected"
        }
        
        eolLabel?.stringValue = doc?.eolType ?? "LF"
        encodingLabel?.stringValue = doc?.encoding ?? "UTF-8"
        languageLabel?.stringValue = doc?.language ?? "Plain Text"

        positionLabel?.setAccessibilityValue(positionLabel?.stringValue)
        selectionLabel?.setAccessibilityValue(selectionLabel?.stringValue)
        eolLabel?.setAccessibilityValue(eolLabel?.stringValue)
        encodingLabel?.setAccessibilityValue(encodingLabel?.stringValue)
        languageLabel?.setAccessibilityValue(languageLabel?.stringValue)
        lengthLabel?.setAccessibilityValue(lengthLabel?.stringValue)
        linesLabel?.setAccessibilityValue(linesLabel?.stringValue)
    }

    /// Shows the typing-mode field's INS or OVR state.
    func setOverwriteMode(_ isOverwrite: Bool) {
        modeLabel?.stringValue = isOverwrite ? "OVR" : "INS"
        modeLabel?.setAccessibilityValue(modeLabel?.stringValue)
    }

    /// Returns the cached index when it still describes the text on screen.
    ///
    /// A single recorded character edit is spliced in incrementally (the edit
    /// band only). Multiple coalesced edits, a tab switch, or a failed
    /// consistency check fall back to one full scan.
    private func cachedLineIndex(for doc: DocumentModel?, textView: NSTextView) -> LineIndex? {
        guard let storage = textView.textStorage else { return nil }
        let storageID = ObjectIdentifier(storage)
        observedStorageID = storageID

        if let cache = lineIndexCache,
           cache.storageID == storageID,
           cache.documentID == doc?.id {
            if pendingEdits.count == 1 {
                let edit = pendingEdits[0]
                pendingEdits.removeAll()
                let updated = cache.index.updating(textView.string,
                                                   editedRange: edit.range,
                                                   changeInLength: edit.changeInLength)
                lineIndexCache = LineIndexCache(documentID: doc?.id,
                                                storageID: storageID,
                                                index: updated)
                return updated
            }
            if pendingEdits.isEmpty, cache.index.textLength == storage.length {
                return cache.index
            }
        }

        pendingEdits.removeAll()
        let index = LineIndex(textView.string)
        lineIndexCache = LineIndexCache(documentID: doc?.id,
                                        storageID: storageID,
                                        index: index)
        return index
    }
}

/// A label that behaves like a button without the button chrome. Only the
/// status bar's INS/OVR field uses it; the rest are plain labels.
private final class ClickableStatusLabel: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

