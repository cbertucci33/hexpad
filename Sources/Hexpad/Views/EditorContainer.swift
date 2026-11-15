import AppKit
import HexpadKit

class EditorContainer: NSView {
    
    let scrollView: NSScrollView
    let textView: MultiCaretTextView
    let ruler: LineNumberGutter

    /// Fixed-width document overview on the trailing edge. It observes the
    /// shared storage and scroll view itself; the container only binds it,
    /// themes it, and makes room for it in the layout.
    let minimap: MinimapView

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
    private var foldEditObserver: NSObjectProtocol?

    // MARK: - Folding
    //
    // Fold state is per document and owned by the editor container, keyed by
    // document id. It cannot live on DocumentModel: that type is Kit-side and
    // deliberately carries no UI/editor state, and it is also outside this
    // slice's scope. It cannot live only on FoldModel either, because the
    // container is reused across tabs and swapping the model for a different
    // document would discard the previous tab's collapsed folds.
    //
    // `foldStates` holds the authoritative collapsed sets; `foldModel` is the
    // derived fold ranges + state pair for the currently bound document.

    /// Collapsed fold state per document id, retained across tab switches.
    private var foldStates: [UUID: FoldState] = [:]

    /// Fold ranges and state for the bound document. `nil` for plain text and
    /// when no document is bound.
    private(set) var foldModel: FoldModel?

    /// Layout-only hider for collapsed fold content. It is retained here because
    /// `NSLayoutManager.delegate` does not own its delegate.
    private let foldHider = FoldGlyphHider()

    /// Set when a text edit changed the document under the current model and
    /// the foldable ranges need recomputing before markers are next drawn.
    private var foldModelIsStale = false

    /// Markers the fold gutter should draw for the selected document.
    var foldMarkers: [Int: FoldMarkerState] {
        FoldMargin.markers(for: foldModel)
    }

    /// Document ranges currently hidden by collapsed folds.
    var foldHiddenRanges: [NSRange] { foldHider.hiddenRanges }

    // MARK: - Bookmarks
    //
    // Like folds, bookmarks are per document and owned here, keyed by document
    // id so switching tabs restores the previous tab's markers. Unlike folds,
    // `DocumentModel.bookmarkState` also persists them to the session, so the
    // state round-trips through the model on bind/unbind and on every edit.

    /// Bookmark state per document id, retained across tab switches.
    private var bookmarkStates: [UUID: BookmarkState] = [:]

    /// Bookmarks for the bound document, kept in step with its text.
    private(set) var bookmarkModel: BookmarkModel?

    /// Bookmarked logical lines the gutter should draw circles on.
    var bookmarkLines: Set<Int> {
        Set(bookmarkModel?.bookmarkState.lines ?? [])
    }

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
        minimap = MinimapView(textView: view, scrollView: scrollView)
        
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
        // Persist the outgoing document's bookmarks before the pointer moves to
        // the new document, so every tab's state survives the switch.
        flushBookmarkState()
        let storage = document?.textStorage ?? unboundStorage
        boundDocument = document
        minimap.bind(to: document)
        needsLayout = true
        layoutEditorSubviews()
        guard let layoutManager = textView.layoutManager else {
            assertionFailure("Editor requires the TextKit 1 layout manager")
            return
        }
        if layoutManager.textStorage !== storage {
            isSyncingSelection = true
            layoutManager.replaceTextStorage(storage)
            isSyncingSelection = false
            columnAnchor = nil
            setMultiCaretState(MultiCaretState(caret: textView.selectedRange))
            applyBodyFont()
        }

        // Runs on every bind, including rebinding the same buffer after a
        // language change, so fold ranges always match the current grammar.
        // The collapsed state survives rebuilds because it is stored per
        // document id rather than inside the model.
        bindFolds(for: document)

        // Bookmarks have no language dependency, but rebinding is the moment
        // the container adopts a tab's persisted state.
        bindBookmarks(for: document)
    }

    deinit {
        viewportObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        if let foldEditObserver {
            NotificationCenter.default.removeObserver(foldEditObserver)
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
        minimap.apply(theme: theme)
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
        ruler.foldMarkersProvider = { [weak self] in
            self?.markersForGutter() ?? [:]
        }
        ruler.onToggleFold = { [weak self] line in
            self?.toggleFold(atLine: line)
        }
        ruler.bookmarkLinesProvider = { [weak self] in
            self?.bookmarkLines ?? []
        }
        ruler.onToggleBookmark = { [weak self] line in
            self?.toggleBookmark(atLine: line)
        }

        // Fold content is hidden at the glyph level so the shared text storage
        // and its highlighting attributes are never rewritten. NSTextView leaves
        // the layout manager delegate nil in TextKit 1, so this is additive.
        textView.layoutManager?.delegate = foldHider

        minimap.frame = NSRect(x: 820, y: 0, width: MinimapView.width, height: 500)

        addSubview(ruler)
        addSubview(scrollView)
        addSubview(minimap)
        layoutEditorSubviews()
        startViewportObservation()
        startSelectionObservation()
        startFoldObservation()
    }

    // MARK: - Layout

    /// Manual layout: gutter on the leading edge, minimap on the trailing edge,
    /// and the scroll view taking the remaining width. The gutter and minimap
    /// keep their own widths so only the editor area grows on resize.
    private func layoutEditorSubviews() {
        let height = bounds.height
        let available = max(0, bounds.width - LineNumberGutter.width)
        let minimapWidth = minimap.isHidden
            ? 0
            : min(MinimapView.width, available)
        let editorWidth = max(0, available - minimapWidth)

        ruler.frame = NSRect(x: 0, y: 0,
                             width: LineNumberGutter.width,
                             height: height)
        scrollView.frame = NSRect(x: LineNumberGutter.width, y: 0,
                                  width: editorWidth,
                                  height: height)
        minimap.frame = NSRect(x: LineNumberGutter.width + editorWidth, y: 0,
                               width: minimapWidth,
                               height: height)
    }

    override func layout() {
        super.layout()
        layoutEditorSubviews()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutEditorSubviews()
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

    // MARK: - Folding

    /// Toggles the fold that starts on `line` for the selected document.
    ///
    /// - Returns: `true` when a foldable range started on that line.
    @discardableResult
    func toggleFold(atLine line: Int) -> Bool {
        refreshFoldModelIfStale()
        guard var model = foldModel, model.toggleFold(atLine: line) else { return false }
        foldModel = model
        if let id = boundDocument?.id {
            foldStates[id] = model.foldState
        }
        applyFoldVisibility()
        ruler.needsDisplay = true
        return true
    }

    /// Rebuilds the fold model for the bound document's current text and
    /// grammar, preserving that document's collapsed ranges.
    private func bindFolds(for document: DocumentModel?) {
        guard let document else {
            foldModel = nil
            foldModelIsStale = false
            applyFoldVisibility()
            return
        }
        rebuildFoldModel(for: document)
    }

    private func rebuildFoldModel(for document: DocumentModel) {
        guard let language = Language(rawValue: document.language),
              let definition = LexerDefinitions.definition(for: language) else {
            // Plain text (and any language without a definition) has nothing
            // structural to fold.
            foldModel = nil
            foldModelIsStale = false
            applyFoldVisibility()
            return
        }

        let state = foldStates[document.id] ?? FoldState()
        foldModel = FoldModel(text: document.text,
                              definition: definition,
                              foldState: state)
        foldModelIsStale = false
        applyFoldVisibility()
    }

    /// Recomputes foldable ranges after an edit, but only when the gutter or a
    /// fold gesture actually needs them. Edits made while a fold is collapsed
    /// rebuild eagerly so the hidden ranges stay valid.
    private func refreshFoldModelIfStale() {
        guard foldModelIsStale, let document = boundDocument else { return }
        rebuildFoldModel(for: document)
    }

    /// Markers shared with the gutter. Pulled during drawing so an edit that
    /// changed fold structure is reflected in the same frame.
    private func markersForGutter() -> [Int: FoldMarkerState] {
        refreshFoldModelIfStale()
        return FoldMargin.markers(for: foldModel)
    }

    /// Toggles the bookmark on `line` for the selected document.
    ///
    /// - Returns: `true` when `line` exists and its bookmark was toggled.
    @discardableResult
    func toggleBookmark(atLine line: Int) -> Bool {
        guard var model = bookmarkModel, model.isValid(line: line) else { return false }
        model.toggle(line: line)
        adoptBookmarkModel(model)
        return true
    }

    /// Adopts `state` for the bound document, for example after a bookmark
    /// command ran through the registry.
    func applyBookmarkState(_ state: BookmarkState) {
        guard let document = boundDocument else { return }
        adoptBookmarkModel(BookmarkModel(text: document.text, bookmarkState: state))
    }

    /// Adopts a model, writing its state through to the per-document store and
    /// the document's persisted bookmark state.
    private func adoptBookmarkModel(_ model: BookmarkModel) {
        bookmarkModel = model
        if let document = boundDocument {
            bookmarkStates[document.id] = model.bookmarkState
            document.bookmarkState = model.bookmarkState
        }
        ruler.needsDisplay = true
    }

    /// Rebuilds the bookmark model for the bound document, preferring the
    /// in-memory state for this tab and falling back to the persisted state in
    /// `DocumentModel.bookmarkState`.
    private func bindBookmarks(for document: DocumentModel?) {
        guard let document else {
            bookmarkModel = nil
            ruler.needsDisplay = true
            return
        }
        let state = bookmarkStates[document.id] ?? document.bookmarkState
        let model = BookmarkModel(text: document.text, bookmarkState: state)
        bookmarkStates[document.id] = model.bookmarkState
        document.bookmarkState = model.bookmarkState
        bookmarkModel = model
        ruler.needsDisplay = true
    }

    /// Writes the bound document's bookmark state back to it before unbinding.
    private func flushBookmarkState() {
        guard let document = boundDocument, let model = bookmarkModel else { return }
        bookmarkStates[document.id] = model.bookmarkState
        document.bookmarkState = model.bookmarkState
    }

    /// Remaps bookmarks across a text edit so their circles follow the lines.
    ///
    /// A whole-buffer replacement (reload, encoding change, command-driven
    /// replace) cannot be line-mapped meaningfully, so it revalidates the
    /// existing bookmarks against the new text instead of dropping them all.
    private func remapBookmarks(for edit: FoldTextEdit, oldLength: Int) {
        guard var model = bookmarkModel else { return }
        if edit.location == 0, edit.replacedLength > 0, edit.replacedLength >= oldLength {
            model.updateText(boundDocument?.text ?? model.text)
        } else {
            model.remap(for: edit, in: boundDocument?.text ?? model.text)
        }
        adoptBookmarkModel(model)
    }

    /// Observes character edits on the bound storage.
    ///
    /// Attribute-only edits are ignored: the incremental highlighting pipeline
    /// rewrites attributes on every scroll and keystroke, and reacting to those
    /// would rebuild the fold model for work that cannot change a fold span.
    private func startFoldObservation() {
        foldEditObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleFoldEdit(notification)
        }
    }

    private func handleFoldEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage === textView.textStorage,
              storage.editedMask.contains(.editedCharacters),
              let document = boundDocument else { return }

        // NSTextStorage reports the post-edit range plus the length delta. A
        // pure insertion has replacedLength 0; a deletion has insertedLength 0.
        let insertedLength = storage.editedRange.length
        let replacedLength = max(0, insertedLength - storage.changeInLength)
        let edit = FoldTextEdit(location: storage.editedRange.location,
                                replacedLength: replacedLength,
                                insertedLength: insertedLength)

        // Bookmarks are independent of folding: they must follow the text even
        // for plain-text documents (where there is no fold model at all).
        let oldLength = storage.length - storage.changeInLength
        remapBookmarks(for: edit, oldLength: oldLength)

        guard let model = foldModel else { return }

        guard !model.foldState.isEmpty else {
            // No fold is collapsed, so visibility cannot change. Defer the
            // O(document) fold discovery until markers are next drawn.
            foldModelIsStale = true
            return
        }

        // Remapping is cheap and keeps surviving folds; rebuilding the model now
        // keeps the layout hider's hidden ranges aligned with the edited text.
        let remapped = model.foldState.remapped(for: edit)
        foldStates[document.id] = remapped
        foldModel = FoldModel(text: document.text,
                              definition: model.definition,
                              configuration: model.configuration,
                              foldState: remapped)
        foldModelIsStale = false
        applyFoldVisibility()
    }

    /// Hands the model's hidden ranges to the glyph hider and relayouts when
    /// visibility actually changed.
    private func applyFoldVisibility() {
        let hidden = foldModel?.visibility().hiddenRanges ?? []
        guard foldHider.setHiddenRanges(hidden) else { return }
        invalidateFoldLayout()
    }

    /// Invalidates glyph generation for the whole document so hidden ranges take
    /// effect. Fold toggles are user-paced, so the full pass is preferable to
    /// tracking partial ranges through edits.
    private func invalidateFoldLayout() {
        guard let storage = textView.textStorage,
              let layoutManager = textView.layoutManager else { return }
        let length = storage.length
        guard length > 0 else {
            textView.needsDisplay = true
            ruler.needsDisplay = true
            return
        }
        let range = NSRange(location: 0, length: length)
        layoutManager.invalidateGlyphs(forCharacterRange: range,
                                       changeInLength: 0,
                                       actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: range,
                                       actualCharacterRange: nil)
        textView.needsDisplay = true
        ruler.needsDisplay = true
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
