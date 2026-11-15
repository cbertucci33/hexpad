import AppKit
import HexpadKit

class StatusBar: NSView {
    
    private var positionLabel: NSTextField?
    private var selectionLabel: NSTextField?
    private var eolLabel: NSTextField?
    private var encodingLabel: NSTextField?
    private var languageLabel: NSTextField?

    /// A line index plus the identity of the text it was built from.
    ///
    /// `generation` is bumped by `NSTextStorage`'s character-edit
    /// notification; `storageID`/`documentID` prevent a tab switch from reusing
    /// another buffer's offsets. Together they make the cache valid exactly
    /// while the (document, text) pair is unchanged.
    private struct LineIndexCache {
        let documentID: UUID?
        let storageID: ObjectIdentifier
        let generation: Int
        let index: LineIndex
    }

    private var lineIndexCache: LineIndexCache?

    /// Counts character edits on the storage currently being indexed. Attribute
    /// edits are ignored: the highlighter rewrites attributes on every keystroke
    /// and scroll, and attributes cannot move a line start.
    private var textGeneration = 0

    /// The storage the edit observer is currently following. Set on every
    /// `update` so edits to a previously shown tab cannot invalidate the
    /// current tab's cache.
    private var observedStorageID: ObjectIdentifier?

    private var editObserver: NSObjectProtocol?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupUI()
        startEditObservation()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let editObserver {
            NotificationCenter.default.removeObserver(editObserver)
        }
    }

    /// Bumps `textGeneration` whenever the observed buffer's characters change.
    /// Typing, undo, find/replace, line operations and reloads all mutate the
    /// document's single `NSTextStorage`, so this one notification covers every
    /// path that can move a line start (the container already relies on the
    /// same notification for fold/bookmark remapping).
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
            self.textGeneration &+= 1
        }
    }
    
    private func setupUI() {
        let font = NSFont.systemFont(ofSize: 11)
        let height = bounds.height
        
        let pos = NSTextField(labelWithString: "Ln 1, Col 1")
        pos.font = font
        pos.frame = NSRect(x: 8, y: (height - 14) / 2, width: 120, height: 14)
        addSubview(pos)
        positionLabel = pos
        
        let sel = NSTextField(labelWithString: "0 selected")
        sel.font = font
        sel.frame = NSRect(x: 136, y: (height - 14) / 2, width: 100, height: 14)
        addSubview(sel)
        selectionLabel = sel
        
        let eol = NSTextField(labelWithString: "LF")
        eol.font = font
        eol.frame = NSRect(x: 244, y: (height - 14) / 2, width: 40, height: 14)
        addSubview(eol)
        eolLabel = eol
        
        let enc = NSTextField(labelWithString: "UTF-8")
        enc.font = font
        enc.frame = NSRect(x: 292, y: (height - 14) / 2, width: 70, height: 14)
        addSubview(enc)
        encodingLabel = enc
        
        let lang = NSTextField(labelWithString: "Plain Text")
        lang.font = font
        lang.frame = NSRect(x: 370, y: (height - 14) / 2, width: 100, height: 14)
        addSubview(lang)
        languageLabel = lang

        let separator = NSView(frame: .zero)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
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
        let xs: [(CGFloat, CGFloat)] = [(8, 120), (136, 100), (244, 40), (292, 70), (370, 100)]
        let labels = [positionLabel, selectionLabel, eolLabel, encodingLabel, languageLabel]
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
        
        if selRange.length > 0 {
            selectionLabel?.stringValue = "\(selRange.length) selected"
        } else {
            selectionLabel?.stringValue = "0 selected"
        }
        
        eolLabel?.stringValue = doc?.eolType ?? "LF"
        encodingLabel?.stringValue = doc?.encoding ?? "UTF-8"
        languageLabel?.stringValue = doc?.language ?? "Plain Text"
    }

    /// Returns the cached index when it still describes the text on screen,
    /// rebuilding it only on the first update and after a character edit or a
    /// document/tab switch.
    ///
    /// The length check is a cheap guard (O(1)) against a missed notification;
    /// the generation counter is what makes same-length edits (typing over a
    /// selection, undo) rebuild.
    private func cachedLineIndex(for doc: DocumentModel?, textView: NSTextView) -> LineIndex? {
        guard let storage = textView.textStorage else { return nil }
        let storageID = ObjectIdentifier(storage)
        observedStorageID = storageID

        if let cache = lineIndexCache,
           cache.storageID == storageID,
           cache.documentID == doc?.id,
           cache.generation == textGeneration,
           cache.index.textLength == storage.length {
            return cache.index
        }

        let index = LineIndex(textView.string)
        lineIndexCache = LineIndexCache(documentID: doc?.id,
                                        storageID: storageID,
                                        generation: textGeneration,
                                        index: index)
        return index
    }
}
