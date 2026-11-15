import AppKit
import HexpadKit

class EditorContainer: NSView {
    
    let scrollView: NSScrollView
    let textView: MultiCaretTextView
    let ruler: LineNumberGutter

    /// The authoritative multi-caret state for the selected document. The text
    /// view's single selection always mirrors the primary (first) caret; extra
    /// carets live only here, so selection notifications and gestures cannot
    /// create a second, competing source of truth.
    private(set) var multiCaretState = MultiCaretState(caretAt: 0)

    /// True while this container is deliberately moving the text view's
    /// selection to mirror the caret state. The selection observer ignores
    /// those notifications so it does not collapse the extra carets it just set.
    private var isSyncingSelection = false

    /// Anchor of the in-progress Option-drag column selection, if any.
    private var columnAnchor: TextPoint?

    /// The document backing the shared text storage, used for undoable edits.
    private weak var boundDocument: DocumentModel?

    private var selectionObserver: NSObjectProtocol?

    /// Used when no tab is selected, so the text view always has a storage.
    private let unboundStorage = NSTextStorage()

    /// The editor's body font. A document's NSTextStorage has no font of its
    /// own, and swapping one in makes NSTextView fall back to Helvetica 12, so
    /// bind and highlighting must restore this value explicitly.
    private(set) var bodyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Fired when the visible character range changes (scroll or resize).
    var onViewportChange: (() -> Void)?
    /// Fired when the effective light/dark appearance changes.
    var onAppearanceChange: (() -> Void)?

    private var viewportObservers: [NSObjectProtocol] = []
    private var pendingViewportUpdate = false
    
    init() {
        scrollView = NSScrollView()
        let view = MultiCaretTextView()
        textView = view
        ruler = LineNumberGutter(textView: view)
        
        super.init(frame: .zero)
        view.host = self
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Points the editor at the document's shared buffer. The text view never
    /// receives a copy of the text: switching tabs swaps the storage under the
    /// layout manager, so the model and the visible editor are one buffer.
    func bind(to document: DocumentModel?) {
        let storage = document?.textStorage ?? unboundStorage
        boundDocument = document
        guard let layoutManager = textView.layoutManager else {
            assertionFailure("Editor requires the TextKit 1 layout manager")
            return
        }
        guard layoutManager.textStorage !== storage else { return }
        isSyncingSelection = true
        layoutManager.replaceTextStorage(storage)
        isSyncingSelection = false
        columnAnchor = nil
        setMultiCaretState(MultiCaretState(caret: textView.selectedRange))
        applyBodyFont()
    }

    deinit {
        viewportObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
    }

    /// Character range currently visible in the clip view, resolved through the
    /// layout manager rather than by guessing a character-per-pixel ratio.
    func visibleCharacterRange() -> NSRange {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return NSRange(location: 0, length: min(storage.length, 4_000))
        }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect,
                                                  in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                     actualGlyphRange: nil)
        guard charRange.length > 0 else {
            // TextKit has not laid the view out yet; start at the top.
            return NSRange(location: 0, length: min(storage.length, 4_000))
        }
        return charRange
    }

    /// Applies theme chrome. Colors on the text itself are applied per visible
    /// viewport by the window controller.
    func apply(theme: Theme) {
        layer?.backgroundColor = theme.background.cgColor
        textView.backgroundColor = theme.background
        textView.textColor = theme.foreground
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// Changes the global editor font (zoom) and updates the visible buffer.
    func setBodyFont(_ font: NSFont) {
        bodyFont = font
        textView.font = font
        applyBodyFont()
    }

    /// Applies the body font to the currently shared buffer without touching
    /// syntax colours, so the text view never renders with AppKit's default.
    private func applyBodyFont() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.addAttribute(.font, value: bodyFont,
                             range: NSRange(location: 0, length: storage.length))
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        
        textView.font = bodyFont
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.textColor
        textView.drawsBackground = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalRuler = false
        scrollView.hasVerticalRuler = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: LineNumberGutter.width, bottom: 0, right: 0)
        scrollView.frame = NSRect(x: LineNumberGutter.width, y: 0, width: 720, height: 500)
        
        ruler.frame = NSRect(x: 0, y: 0, width: LineNumberGutter.width, height: 500)
        ruler.autoresizingMask = [.height]
        
        addSubview(ruler)
        addSubview(scrollView)
        startViewportObservation()
        startSelectionObservation()
    }

    // MARK: - Multi-caret state

    /// Mirrors ordinary text-view selection changes into the caret state.
    ///
    /// This is the single place where an external selection (click, arrow key,
    /// find navigation, tab switch) collapses the extra carets. The observer is
    /// synchronous (`queue: nil`) so state and rendering agree before the next
    /// run-loop turn, and it flips `isSyncingSelection` off while this container
    /// drives the primary selection itself.
    private func startSelectionObservation() {
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSTextViewDidChangeSelectionNotification"),
            object: textView,
            queue: nil
        ) { [weak self] _ in
            guard let self, !self.isSyncingSelection else { return }
            let selection = self.textView.selectedRange
            // A notification that merely echoes the primary caret must not
            // erase the extra carets it belongs to. NSTextView can post such a
            // notification after a storage edit or a programmatic selection.
            if self.multiCaretState.count > 1,
               self.multiCaretState.primaryCaret == selection {
                self.textView.needsDisplay = true
                return
            }
            self.columnAnchor = nil
            self.multiCaretState = MultiCaretState(caret: selection)
            self.textView.needsDisplay = true
        }
    }

    /// Replaces the caret state and makes the primary caret the text view's
    /// single selection. Extra carets are drawn by the text view.
    private func setMultiCaretState(_ state: MultiCaretState, scrollPrimary: Bool = false) {
        let normalized = normalizedForCurrentText(state)
        multiCaretState = normalized.carets.isEmpty
            ? MultiCaretState(caretAt: 0)
            : normalized

        guard let primary = multiCaretState.primaryCaret else { return }
        isSyncingSelection = true
        textView.setSelectedRange(primary)
        isSyncingSelection = false
        if scrollPrimary {
            textView.scrollRangeToVisible(primary)
        }
        textView.needsDisplay = true
    }

    /// Drops carets that no longer fit the current buffer after a reload or
    /// programmatic whole-document replacement.
    private func normalizedForCurrentText(_ state: MultiCaretState) -> MultiCaretState {
        let length = (textView.string as NSString).length
        let carets = state.carets.map { caret -> NSRange in
            let location = min(max(0, caret.location), length)
            return NSRange(location: location,
                           length: min(max(0, caret.length), length - location))
        }
        return MultiCaretState(carets: carets)
    }

    /// Adds (or toggles off) an extra caret. Re-clicking the primary position
    /// collapses back to that single caret.
    func placeAdditionalCaret(atCharacterIndex index: Int) {
        let length = (textView.string as NSString).length
        let target = min(max(0, index), length)

        if let primary = multiCaretState.primaryCaret, target == primary.location {
            collapseMultiCaret()
            return
        }

        var state = multiCaretState
        if let existing = state.carets.firstIndex(where: { $0.location == target }) {
            var carets = state.carets
            carets.remove(at: existing)
            state = MultiCaretState(carets: carets)
        } else {
            state.addCaret(at: target)
        }
        setMultiCaretState(state)
    }

    /// Starts an Option-drag column selection at the given character index.
    func beginColumnSelection(atCharacterIndex index: Int) {
        let text = textView.string
        columnAnchor = columnPoint(at: index, in: text)
        updateColumnSelection(toCharacterIndex: index)
    }

    /// Extends the in-progress column selection to another character index and
    /// maps the rectangle through ``ColumnEditing`` into carets.
    func updateColumnSelection(toCharacterIndex index: Int) {
        guard let anchor = columnAnchor else { return }
        let text = textView.string
        let current = columnPoint(at: index, in: text)
        let rectangle = ColumnRectangle(start: anchor, end: current)
        let state = ColumnEditing.carets(in: text, rectangle: rectangle)
        guard !state.isEmpty else { return }
        setMultiCaretState(state)
    }

    func endColumnSelection() {
        columnAnchor = nil
    }

    /// Collapses every extra caret, keeping the primary selection.
    func collapseMultiCaret() {
        guard let primary = multiCaretState.primaryCaret else { return }
        setMultiCaretState(MultiCaretState(caret: primary))
    }

    /// Types `insertion` at every caret as one undoable edit.
    func applyMultiCaretInsertion(_ insertion: String) {
        applyMultiCaretTransform(MultiCaretEditing.insertionTransform(insertion))
    }

    /// Backspaces (or forward-deletes) at every caret as one undoable edit.
    func applyMultiCaretDeletion(forward: Bool) {
        applyMultiCaretTransform(MultiCaretEditing.deletionTransform(forward: forward))
    }

    /// Resolves a character index to a `ColumnEditing` line/column point.
    private func columnPoint(at index: Int, in text: String) -> TextPoint {
        let document = text as NSString
        let clamped = min(max(0, index), document.length)
        let lines = ColumnEditing.lines(in: text)
        guard !lines.isEmpty else { return TextPoint(line: 0, column: 0) }

        var lineIndex = lines.count - 1
        for (candidate, line) in lines.enumerated()
            where clamped < line.fullRange.upperBound {
            lineIndex = candidate
            break
        }

        let line = lines[lineIndex]
        let column = min(max(0, clamped - line.contentRange.location), line.columnCount)
        return TextPoint(line: lineIndex, column: column)
    }

    /// Runs one transform through ``MultiCaretApplier`` and commits the result
    /// as the smallest possible `DocumentModel` replacement, so every caret is
    /// edited but Cmd+Z still undoes the action in one step.
    @discardableResult
    private func applyMultiCaretTransform(_ transform: MultiCaretApplier.TextTransform) -> Bool {
        guard let document = boundDocument else { return false }

        let oldText = document.text
        let oldState = multiCaretState
        let result = MultiCaretApplier.apply(transform, to: oldText, state: oldState)

        guard result.text != oldText else {
            if result.state != oldState {
                setMultiCaretState(result.state)
            }
            return false
        }

        isSyncingSelection = true
        defer { isSyncingSelection = false }

        if let change = MultiCaretEditing.change(from: oldText, to: result.text) {
            document.replaceCharacters(in: change.range, with: change.replacement)
        }
        // Defensive fallback: the diff must reproduce the applier's document.
        if document.text != result.text {
            document.replaceAllText(with: result.text)
        }

        multiCaretState = normalizedForCurrentText(result.state)
        if let primary = multiCaretState.primaryCaret {
            textView.setSelectedRange(primary)
            textView.scrollRangeToVisible(primary)
        }
        textView.needsDisplay = true
        return true
    }

    // MARK: - Viewport observation

    private func startViewportObservation() {
        let center = NotificationCenter.default
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true

        let watched: [(Any, Notification.Name)] = [
            (clip, NSView.boundsDidChangeNotification),
            (clip, NSView.frameDidChangeNotification)
        ]
        for (object, name) in watched {
            viewportObservers.append(center.addObserver(forName: name,
                                                        object: object,
                                                        queue: .main) { [weak self] _ in
                self?.scheduleViewportChange()
            })
        }
    }

    /// Coalesces continuous scrolling into one viewport update. The controller
    /// still skips the work entirely while the viewport stays inside the
    /// already-highlighted band.
    private func scheduleViewportChange() {
        guard !pendingViewportUpdate else { return }
        pendingViewportUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingViewportUpdate = false
            self.onViewportChange?()
        }
    }
}

// MARK: - MultiCaretTextViewHost

extension EditorContainer: MultiCaretTextViewHost {}
