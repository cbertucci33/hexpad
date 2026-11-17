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
    /// Language the models were last built for. A same-document rebind with a
    /// new language must still rebuild folds/bookmarks/minimap.
    private(set) var boundLanguage: String?

    /// Test/diagnostic hook: number of full bookmark-model builds. Same-document
    /// binds must not increment this.
    private(set) var bookmarkBindCount = 0

    /// True when this container already owns `document`'s models for the
    /// current language. Compared by identity, never by text.
    private func isBound(to document: DocumentModel?) -> Bool {
        guard let current = boundDocument, let document else {
            return boundDocument == nil && document == nil
        }
        return current === document && boundLanguage == document.language
    }

    private var selectionObserver: NSObjectProtocol?
    private var foldEditObserver: NSObjectProtocol?

    // MARK: - Folding
    //
    // Fold state is per document, keyed by document id here and mirrored into
    // `DocumentModel.foldState`. It cannot live only on FoldModel: the
    // container is reused across tabs, and swapping the model for a different
    // document would discard the previous tab's collapsed folds. It cannot live
    // only on DocumentModel either, because every mutation would have to round
    // trip through the model before the fold model could use it.
    //
    // `foldStates` holds the live collapsed sets; `foldModel` is the derived
    // fold ranges + state pair for the currently bound document. Every fold
    // mutation updates both the dictionary and the model's persisted
    // `foldState`, so the session save path always sees the current state.

    /// Collapsed fold state per document id, retained across tab switches.
    private var foldStates: [UUID: FoldState] = [:]

    /// Fold ranges and state for the bound document. `nil` for plain text and
    /// when no document is bound.
    ///
    /// Reading the model refreshes a stale one first, so a caller that inspects
    /// the derived ranges after an edit never sees the previous document's
    /// discovery. The edit path itself reads `cachedFoldModel` directly because
    /// its whole point is to defer that refresh.
    private(set) var foldModel: FoldModel? {
        get {
            refreshFoldModelIfStale()
            return cachedFoldModel
        }
        set { cachedFoldModel = newValue }
    }

    private var cachedFoldModel: FoldModel?

    /// Layout-only hider for collapsed fold content. It is retained here because
    /// `NSLayoutManager.delegate` does not own its delegate.
    private let foldHider = FoldGlyphHider()

    /// Set when a text edit changed the document under the current model and
    /// the foldable ranges need recomputing before markers are next drawn.
    private var foldModelIsStale = false

    /// Number of times the fold model has been rebuilt for the bound document.
    /// Diagnostic/test hook: an edit must mark the model stale without paying
    /// for a rebuild until markers or visibility actually need it.
    private(set) var foldModelRebuildCount = 0

    /// Markers the fold gutter should draw for the selected document. Pulling
    /// a marker refreshes a stale model first, so the gutter never draws one
    /// edit behind.
    var foldMarkers: [Int: FoldMarkerState] {
        refreshFoldModelIfStale()
        return FoldMargin.markers(for: foldModel)
    }

    /// Document ranges currently hidden by collapsed folds. Reading visibility
    /// is the other lazy trigger: the ranges are recomputed from the remapped
    /// fold state before they are handed to layout or to a caller.
    var foldHiddenRanges: [NSRange] {
        refreshFoldModelIfStale()
        return foldHider.foldHiddenRanges
    }

    // MARK: - Bookmarks
    //
    // Like folds, bookmarks are per document and owned here, keyed by document
    // id so switching tabs restores the previous tab's markers. Like fold
    // state, `DocumentModel.bookmarkState` also persists them to the session,
    // so the state round-trips through the model on bind/unbind and on every
    // edit.

    /// Bookmark state per document id, retained across tab switches.
    private var bookmarkStates: [UUID: BookmarkState] = [:]

    /// Bookmarks for the bound document, kept in step with its text.
    private(set) var bookmarkModel: BookmarkModel?

    /// Number of edit remaps performed for the bound document. Diagnostic/test
    /// hook: edits with no bookmarks must skip the remap entirely.
    private(set) var bookmarkRemapCount = 0

    /// Set when an edit changed the text while no bookmarks existed. The model's
    /// copy of the text is only used for line-validity questions, so it is
    /// refreshed lazily the next time one is actually asked instead of doing
    /// per-keystroke line math.
    private var bookmarkModelTextIsStale = false

    /// Bookmarked logical lines the gutter should draw circles on.
    var bookmarkLines: Set<Int> {
        Set(bookmarkModel?.bookmarkState.lines ?? [])
    }

    // MARK: - Hidden lines
    //
    // View > Hide Lines hides whole lines without deleting them. Like folds and
    // bookmarks the state is per document, keyed by id here and mirrored into
    // `DocumentModel.editorState.hiddenLinesState`, which is what the session
    // save path stores. The state is line-based; the derived UTF-16 spans are
    // recomputed from the live text (on bind, on hide/unhide, and after edits)
    // and handed to the same glyph hider collapsing folds uses.

    /// Hidden-line state per document id, retained across tab switches.
    private var hideStates: [UUID: HideLinesState] = [:]

    /// UTF-16 spans currently hidden by the hide-lines mask, for the bound
    /// document. Cached so the selection observer stays cheap.
    private var hiddenLineCharacterRanges: [NSRange] = []

    /// Logical line count of the bound document at the last span recompute.
    /// Cached with the spans so the gutter draw pass never rescans the text.
    private var hiddenLineTextLineCount = 0

    /// Hidden-line state for the bound document.
    var hiddenLinesState: HideLinesState {
        guard let document = boundDocument else { return HideLinesState() }
        return hideStates[document.id] ?? document.editorState.hiddenLinesState
    }

    /// Whether the bound document has any hidden line range.
    var hasHiddenLines: Bool { !hiddenLinesState.isEmpty }

    /// Hidden line ranges for the bound document, in document order.
    var hiddenLineRanges: [ClosedRange<Int>] { hiddenLinesState.lineRanges }

    /// Anchor line → hidden range, for the gutter's unhide symbols.
    var hiddenLineMarkers: [Int: ClosedRange<Int>] {
        let state = hiddenLinesState
        guard !state.isEmpty else { return [:] }
        var markers: [Int: ClosedRange<Int>] = [:]
        for range in state.lineRanges {
            if let anchor = state.anchorLine(for: range, lineCount: hiddenLineTextLineCount) {
                markers[anchor] = range
            }
        }
        return markers
    }

    /// UTF-16 spans the glyph hider suppresses for hidden lines. Diagnostic /
    /// test hook; fold-only spans remain available as ``foldHiddenRanges``.
    var hiddenLineCharacterSpans: [NSRange] { hiddenLineCharacterRanges }

    /// Used when no tab is selected, so the text view always has a storage.
    private let unboundStorage = NSTextStorage()

    /// Default and minimum body-font point sizes. Zoom is expressed as a
    /// multiplier over the base (preference) font, so these keep the persisted
    /// multiplier independent of the user's chosen font size.
    static let defaultFontSize: CGFloat = 13
    static let minimumFontSize: CGFloat = 8

    /// The unzoomed font chosen by preferences. `bodyFont` is the rendered font
    /// after the bound document's zoom multiplier is applied.
    private var baseFont = NSFont.monospacedSystemFont(ofSize: defaultFontSize, weight: .regular)

    /// The editor's body font. A document's NSTextStorage has no font of its
    /// own, and swapping one in makes NSTextView fall back to Helvetica 12, so
    /// bind and highlighting must restore this value explicitly.
    private(set) var bodyFont = NSFont.monospacedSystemFont(ofSize: defaultFontSize, weight: .regular)

    /// Current zoom as a multiplier of the base font. Persisted per document in
    /// `DocumentModel.editorState.zoomScale`.
    var zoomScale: CGFloat {
        baseFont.pointSize > 0 ? bodyFont.pointSize / baseFont.pointSize : 1
    }

    /// Whether long lines soft-wrap. This is the inverse of the text view's
    /// horizontal resizability, exactly as View > Word Wrap and the preference
    /// have always mapped it.
    var isWordWrapEnabled: Bool {
        !textView.isHorizontallyResizable
    }

    /// A scroll origin to re-apply after the next layout pass. AppKit only
    /// knows the new document's height once layout has run, so a restore that
    /// the clip view clamped during bind is retried here.
    private var pendingScrollOffset: CGPoint?
    private var pendingScrollDocumentID: UUID?

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
    ///
    /// Rebinding the same document (focus changes, chrome refreshes) is a
    /// no-op: fold/bookmark models and the minimap already track that buffer
    /// incrementally. Pass `force` for a real re-adoption (language change,
    /// reload) that must rebuild them.
    func bind(to document: DocumentModel?, force: Bool = false) {
        if !force, isBound(to: document) { return }
        // Persist the outgoing document's live caret/scroll/wrap/zoom before
        // the pointer moves to the new document, so switching tabs neither
        // discards the old tab's state nor leaks it into the new tab.
        if let outgoing = boundDocument {
            captureEditorState(into: outgoing)
        }
        // Persist the outgoing document's bookmarks before the pointer moves to
        // the new document, so every tab's state survives the switch.
        flushBookmarkState()
        let storage = document?.textStorage ?? unboundStorage
        boundDocument = document
        boundLanguage = document?.language
        minimap.bind(to: document, force: force)
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
            // Reset before adopting the incoming document's caret. NSTextView
            // keeps its selection across a storage swap, so leaving that value
            // in place would move the new tab's caret to the old tab's offset.
            setMultiCaretState(MultiCaretState(caretAt: 0))
            applyBodyFont()
            // The gutter registered its redraw observer on the previous tab's
            // storage; re-subscribe to the buffer now in use.
            ruler.textStorageDidChange()
        }

        // Runs on every bind, including rebinding the same buffer after a
        // language change, so fold ranges always match the current grammar.
        // The collapsed state survives rebuilds because it is stored per
        // document id rather than inside the model.
        bindFolds(for: document)

        // Bookmarks have no language dependency, but rebinding is the moment
        // the container adopts a tab's persisted state.
        bindBookmarks(for: document)

        // Hidden lines are also per document; binding re-resolves their line
        // ranges against the buffer that is now live.
        bindHiddenLines(for: document)

        // Adopt the incoming document's persisted editor state. This runs after
        // the storage swap and fold/bookmark binding so the caret is clamped
        // against the buffer that is actually visible.
        applyEditorState(from: document)
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

    /// Changes the base editor font (the Preferences choice) and re-applies the
    /// current zoom on top of it. The visible buffer is updated in place.
    func setBodyFont(_ font: NSFont) {
        let scale = zoomScale
        baseFont = font
        applyZoomScale(scale, writingThrough: false)
    }

    /// Shows or hides the document map (View > Document Map and the
    /// preference). The minimap reserves width only while visible;
    /// `layoutEditorSubviews` reflows the editor around it either way.
    func setMinimapVisible(_ visible: Bool) {
        minimap.isDocumentMapVisible = visible
        needsLayout = true
        layoutEditorSubviews()
    }

    /// Applies the global View > Show Symbol options to the text view. Symbol
    /// drawing itself is viewport-scoped in `MultiCaretTextView.draw(_:)`; this
    /// only flips the flags and schedules one repaint.
    func setShowSymbols(showWhitespace: Bool,
                        showEOL: Bool,
                        showIndentGuide: Bool,
                        tabSize: Int) {
        textView.setSymbolVisibility(showWhitespace: showWhitespace,
                                     showEOL: showEOL,
                                     showIndentGuide: showIndentGuide,
                                     tabSize: tabSize)
    }

    /// Applies a zoom multiplier over the base font and persists it on the
    /// bound document, so the View > Zoom commands survive a tab switch.
    func setZoomScale(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        applyZoomScale(scale, writingThrough: true)
    }

    /// Steps zoom by whole points, matching the one-point View menu commands.
    func adjustZoom(byPoints delta: CGFloat) {
        guard delta.isFinite else { return }
        let target = max(Self.minimumFontSize, bodyFont.pointSize + delta)
        setZoomScale(target / baseFont.pointSize)
    }

    /// Restores 100% zoom over the base font.
    func resetZoom() {
        setZoomScale(1)
    }

    /// Enables or disables soft wrap and persists the choice on the bound
    /// document.
    @discardableResult
    func setWordWrapEnabled(_ enabled: Bool) -> Bool {
        let changed = isWordWrapEnabled != enabled
        textView.isHorizontallyResizable = !enabled
        if changed {
            textView.needsDisplay = true
        }
        boundDocument?.wordWrapEnabled = enabled
        return changed
    }

    /// Writes the bound document's live caret, scroll origin, wrap and zoom
    /// back to `DocumentModel.editorState`. Bind calls this for the outgoing
    /// document; the session save path calls it for the tab that is still open.
    func captureEditorState() {
        guard let document = boundDocument else { return }
        captureEditorState(into: document)
    }

    private func captureEditorState(into document: DocumentModel) {
        let length = document.textStorage.length
        let selection = textView.selectedRange
        let location = min(max(0, selection.location), length)
        document.caretRange = NSRange(location: location,
                                      length: min(max(0, selection.length),
                                                  length - location))
        document.scrollOffset = scrollView.contentView.bounds.origin
        document.wordWrapEnabled = isWordWrapEnabled
        document.zoomScale = zoomScale
        // Hidden lines are already written through on every hide/unhide, but
        // flushing here covers a state adopted from a session that the user
        // never touched again.
        if let state = hideStates[document.id] {
            document.editorState.hiddenLinesState = state
        }
    }

    /// Adopts a document's persisted editor state, clamping the caret to the
    /// document so a stale session can never index past the buffer.
    private func applyEditorState(from document: DocumentModel?) {
        guard let document else {
            setWordWrapEnabled(false)
            applyZoomScale(1, writingThrough: false)
            setMultiCaretState(MultiCaretState(caretAt: 0))
            applyScrollOffset(.zero)
            return
        }

        let state = document.editorState
        setWordWrapEnabled(state.wordWrapEnabled)
        applyZoomScale(state.zoomScale, writingThrough: false)

        let length = document.textStorage.length
        let location = min(max(0, state.caretRange.location), length)
        let caret = NSRange(location: location,
                            length: min(max(0, state.caretRange.length),
                                        length - location))
        setMultiCaretState(MultiCaretState(caret: caret))
        applyScrollOffset(state.scrollOffset)
    }

    /// Renders `scale` over the current base font. The whole-buffer attribute
    /// pass only runs when the rendered font actually changes, so rebinding a
    /// tab does not repaint text that already has the right font.
    private func applyZoomScale(_ scale: CGFloat, writingThrough: Bool) {
        let clamped = max(Self.minimumFontSize / baseFont.pointSize, scale)
        let size = baseFont.pointSize * clamped
        let font = NSFont(descriptor: baseFont.fontDescriptor, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if abs(bodyFont.pointSize - font.pointSize) > 0.0001
            || bodyFont.fontName != font.fontName {
            bodyFont = font
            textView.font = font
            applyBodyFont()
        }
        if writingThrough {
            boundDocument?.zoomScale = zoomScale
        }
    }

    /// Scrolls to `offset` now, and schedules one retry after layout when the
    /// clip view clamped it (for example while a restored session is still
    /// being laid out).
    private func applyScrollOffset(_ offset: CGPoint) {
        guard offset.x.isFinite, offset.y.isFinite else { return }
        let target = CGPoint(x: max(0, offset.x), y: max(0, offset.y))
        scrollNow(to: target)
        let actual = scrollView.contentView.bounds.origin
        if abs(actual.x - target.x) > 0.5 || abs(actual.y - target.y) > 0.5 {
            pendingScrollOffset = target
            pendingScrollDocumentID = boundDocument?.id
        } else {
            pendingScrollOffset = nil
            pendingScrollDocumentID = nil
        }
    }

    private func scrollNow(to offset: CGPoint) {
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Re-applies a scroll restore that had to wait for the new document's
    /// height to be laid out.
    private func applyPendingScrollOffset() {
        guard let offset = pendingScrollOffset,
              pendingScrollDocumentID == boundDocument?.id else { return }
        pendingScrollOffset = nil
        pendingScrollDocumentID = nil
        scrollNow(to: offset)
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
        ruler.hiddenLinesProvider = { [weak self] in
            guard let self else { return .empty }
            return HiddenLinesPresentation(state: self.hiddenLinesState,
                                           lineCount: self.hiddenLineTextLineCount)
        }
        ruler.hiddenRangeMarkersProvider = { [weak self] in
            self?.hiddenLineMarkers ?? [:]
        }
        ruler.onUnhideHiddenRange = { [weak self] range in
            self?.unhideLines(range)
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
        applyPendingScrollOffset()
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
            // Clamp a caret that landed inside hidden text, and unhide a block
            // the user just selected across (N++'s second unhide gesture).
            self.reconcileSelectionWithHiddenLines(selection)
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

    /// Types `insertion` in overwrite mode at every caret as one undoable edit.
    ///
    /// A zero-length caret replaces the composed character it sits on, except
    /// at a line ending or the end of the buffer, where typing appends. A caret
    /// with a selection replaces it exactly like normal typing.
    func applyMultiCaretOverwrite(_ insertion: String) {
        applyMultiCaretTransform(Self.overwriteTransform(insertion))
    }

    private static func overwriteTransform(_ insertion: String)
        -> MultiCaretApplier.TextTransform {
        let insertedLength = (insertion as NSString).length
        return { text, selection in
            let document = NSMutableString(string: text)
            let location = max(0, min(selection.location, document.length))
            let selectedLength = max(0, min(selection.length, document.length - location))
            var range = NSRange(location: location, length: selectedLength)
            if selectedLength == 0, location < document.length {
                let unit = document.character(at: location)
                if unit != 10, unit != 13 {
                    range = document.rangeOfComposedCharacterSequence(at: location)
                }
            }
            document.replaceCharacters(in: range, with: insertion)
            return (document as String,
                    NSRange(location: range.location + insertedLength, length: 0))
        }
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
    /// to the document as one undoable action.
    ///
    /// A single caret commits the smallest contiguous replacement, exactly like
    /// a plain text view. Multiple carets commit one replacement per caret
    /// instead of one span covering every edit: the storage observer then
    /// remaps bookmarks and folds across each small, disjoint edit, so content
    /// between two distant carets is never treated as replaced. Every per-caret
    /// replacement shares one undo group, so Cmd+Z still reverts the whole
    /// action in a single step.
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

        // The per-caret replay must reproduce the applier's document exactly.
        // If it ever does not, fall back to the historical single replacement,
        // which is still correct, just coarser for bookmark/fold remapping.
        let perCaret = oldState.count > 1
            ? perCaretEdits(transform, in: oldText, carets: oldState.carets)
            : nil

        if let perCaret, perCaret.text == result.text, !perCaret.edits.isEmpty {
            let undoManager = document.undoManager
            let grouped = perCaret.edits.count > 1
            if grouped { undoManager.beginUndoGrouping() }
            for edit in perCaret.edits {
                document.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            // Defensive fallback: the per-caret edits must reproduce the
            // applier's document.
            if document.text != result.text {
                document.replaceAllText(with: result.text)
            }
            if grouped { undoManager.endUndoGrouping() }
        } else if let change = MultiCaretEditing.change(from: oldText, to: result.text) {
            document.replaceCharacters(in: change.range, with: change.replacement)
            // Defensive fallback: the diff must reproduce the applier's document.
            if document.text != result.text {
                document.replaceAllText(with: result.text)
            }
        }

        multiCaretState = normalizedForCurrentText(result.state)
        if let primary = multiCaretState.primaryCaret {
            textView.setSelectedRange(primary)
            textView.scrollRangeToVisible(primary)
        }
        textView.needsDisplay = true
        return true
    }

    /// The disjoint replacements that produce each caret's edit.
    ///
    /// ``MultiCaretApplier`` applies transforms bottom-most first and reports
    /// only the final document. Replaying that same order yields the individual
    /// replacements, which keeps the storage observer's bookmark and fold
    /// remapping scoped to the text each caret actually touched.
    ///
    /// An edit below a caret cannot move it, so every caret offset is still
    /// valid in the evolving document. Callers compare the returned text with
    /// the applier's result and fall back to a single replacement if they ever
    /// differ.
    private func perCaretEdits(_ transform: MultiCaretApplier.TextTransform,
                               in text: String,
                               carets: [NSRange])
        -> (edits: [MultiCaretEditing.TextChange], text: String) {
        var document = text
        var edits: [MultiCaretEditing.TextChange] = []
        for caret in carets.reversed() {
            let result = transform(document, caret)
            if let change = MultiCaretEditing.change(from: document, to: result.text) {
                edits.append(change)
                document = result.text
            }
        }
        return (edits, document)
    }

    // MARK: - Folding

    /// Toggles the fold that starts on `line` for the selected document.
    ///
    /// - Returns: `true` when a foldable range started on that line.
    @discardableResult
    func toggleFold(atLine line: Int) -> Bool {
        refreshFoldModelIfStale()
        guard var model = foldModel, model.toggleFold(atLine: line) else { return false }
        adoptFoldStateAndRedraw(model)
        return true
    }

    /// Whether the bound document has any foldable range at all.
    ///
    /// Menu validation reads this so Fold All / Unfold All disable for plain
    /// text (or a language with no fold metadata) instead of silently doing
    /// nothing. Like every other fold read it refreshes a stale model first.
    var hasFoldableRanges: Bool {
        refreshFoldModelIfStale()
        guard let model = foldModel else { return false }
        return !model.foldableRanges.isEmpty
    }

    /// Collapses every foldable range in the bound document.
    ///
    /// Routes through ``FoldModel/foldAll()`` and writes the resulting state
    /// back through ``DocumentModel/foldState`` exactly like a single fold
    /// toggle, so a session save sees the same collapsed set.
    ///
    /// - Returns: The number of ranges newly collapsed.
    @discardableResult
    func foldAll() -> Int {
        refreshFoldModelIfStale()
        guard var model = foldModel else { return 0 }
        let changed = model.foldAll()
        guard changed > 0 else { return 0 }
        adoptFoldStateAndRedraw(model)
        return changed
    }

    /// Expands every collapsed range in the bound document.
    ///
    /// - Returns: The number of ranges newly expanded.
    @discardableResult
    func unfoldAll() -> Int {
        refreshFoldModelIfStale()
        guard var model = foldModel else { return 0 }
        let changed = model.unfoldAll()
        guard changed > 0 else { return 0 }
        adoptFoldStateAndRedraw(model)
        return changed
    }

    /// Expands every foldable range that contains `location`.
    ///
    /// Navigation uses this to make a target line visible under N++ fold
    /// semantics: expanding the ancestors of a position, rather than merely
    /// moving the caret, is what guarantees the destination is not left inside
    /// hidden text after Fold All. Ranges are removed outermost first (the
    /// model's order), so an outer fold is opened before any nested fold that
    /// also contains the target.
    ///
    /// The resulting state is written through `DocumentModel.foldState` by
    /// ``adoptFoldStateAndRedraw(_:)`` exactly like a gutter toggle or Fold All,
    /// and visibility is reapplied before the caller scrolls.
    ///
    /// - Returns: `true` when at least one collapsed range was expanded.
    @discardableResult
    func reveal(location: Int) -> Bool {
        refreshFoldModelIfStale()
        guard let document = boundDocument, var model = foldModel else { return false }

        // A target outside the buffer cannot be inside a fold. Clamping also
        // keeps a stale symbol offset from indexing past the current text.
        let length = (document.text as NSString).length
        let target = min(max(0, location), length)
        let containing = model.foldableRanges.filter {
            $0.location <= target && target < $0.upperBound
        }

        var expanded = false
        for fold in containing {
            if model.unfold(fold) {
                expanded = true
            }
        }
        guard expanded else { return false }

        adoptFoldStateAndRedraw(model)
        return true
    }

    /// Adopts a folded model, persists its state on the document, and repaints
    /// the fold margin and hidden content. Shared by every fold mutation so
    /// they cannot drift in what they write through or invalidate.
    private func adoptFoldStateAndRedraw(_ model: FoldModel) {
        foldModel = model
        if let document = boundDocument {
            adoptFoldState(model.foldState, for: document)
        }
        applyFoldVisibility()
        ruler.needsDisplay = true
    }

    /// Records `state` as the live collapsed set for `document` and writes it
    /// through to `DocumentModel.foldState`, which is what the session save
    /// path stores. Keeping both in step here means tab switches and app
    /// restarts see the same folds.
    private func adoptFoldState(_ state: FoldState, for document: DocumentModel) {
        foldStates[document.id] = state
        document.foldState = state
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
        // The first bind for this tab adopts the persisted projection. Later
        // binds keep the in-memory state: it is the newer of the two, because
        // toggles and edits write through to it immediately.
        if foldStates[document.id] == nil {
            foldStates[document.id] = document.foldState
        }
        rebuildFoldModel(for: document)
    }

    private func rebuildFoldModel(for document: DocumentModel) {
        foldModelRebuildCount += 1
        guard let language = Language(rawValue: document.language),
              let definition = LexerDefinitions.definition(for: language) else {
            // Plain text (and any language without a definition) has nothing
            // structural to fold.
            foldModel = nil
            foldModelIsStale = false
            applyFoldVisibility()
            return
        }

        let state = foldStates[document.id] ?? document.foldState
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
        syncBookmarkModelTextIfNeeded()
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
        bookmarkModelTextIsStale = false
        if let document = boundDocument {
            bookmarkStates[document.id] = model.bookmarkState
            document.bookmarkState = model.bookmarkState
        }
        ruler.needsDisplay = true
    }

    /// Refreshes the bookmark model's copy of the document text after a run of
    /// edits that happened while no bookmarks existed. Only consumers that ask
    /// line-validity questions need this; marker drawing reads the empty state.
    private func syncBookmarkModelTextIfNeeded() {
        guard bookmarkModelTextIsStale,
              let document = boundDocument,
              var model = bookmarkModel else { return }
        model.updateText(document.text)
        bookmarkModel = model
        bookmarkModelTextIsStale = false
    }

    /// Rebuilds the bookmark model for the bound document, preferring the
    /// in-memory state for this tab and falling back to the persisted state in
    /// `DocumentModel.bookmarkState`.
    private func bindBookmarks(for document: DocumentModel?) {
        guard let document else {
            bookmarkModel = nil
            bookmarkModelTextIsStale = false
            ruler.needsDisplay = true
            return
        }
        let state = bookmarkStates[document.id] ?? document.bookmarkState
        let model = BookmarkModel(text: document.text, bookmarkState: state)
        bookmarkBindCount += 1
        bookmarkStates[document.id] = model.bookmarkState
        document.bookmarkState = model.bookmarkState
        bookmarkModel = model
        bookmarkModelTextIsStale = false
        ruler.needsDisplay = true
    }

    /// Writes the bound document's bookmark state back to it before unbinding.
    private func flushBookmarkState() {
        guard let document = boundDocument, let model = bookmarkModel else { return }
        bookmarkStates[document.id] = model.bookmarkState
        document.bookmarkState = model.bookmarkState
    }

    /// Drops the per-document caches kept for a tab that has been closed.
    /// Called by the controller once the document is no longer open in either
    /// group, so a long session cannot retain every closed tab's state.
    func forgetDocumentState(for id: UUID) {
        foldStates.removeValue(forKey: id)
        bookmarkStates.removeValue(forKey: id)
        hideStates.removeValue(forKey: id)
    }

    // MARK: - Hidden lines

    /// Hides the selected line range, or the caret's line when the selection is
    /// collapsed.
    ///
    /// Hiding is presentation-only: the text stays in the buffer, so search,
    /// line operations and saving still see it. Whole lines are hidden,
    /// including their trailing newline, which is what makes the following
    /// visible line move up into the hidden row's place.
    ///
    /// - Returns: `true` when the state changed. Hiding every remaining line is
    ///   refused: a fully hidden document has no visible line to click and no
    ///   layout, so the margin/selection unhide affordances would vanish.
    @discardableResult
    func hideSelectedLines() -> Bool {
        guard let document = boundDocument else { return false }
        let length = document.textStorage.length
        guard length > 0 else { return false }

        let index = LineIndex(document.text)
        let lineCount = index.count
        guard lineCount > 0 else { return false }

        let selection = textView.selectedRange
        let start = min(max(0, selection.location), length)
        // The last character the selection touches, so a selection ending at a
        // line start does not pull the next line into the hide range.
        let end = selection.length > 0
            ? min(length, NSMaxRange(selection)) - 1
            : start
        let firstLine = index.line(of: min(start, end))
        let lastLine = index.line(of: max(start, end))
        guard lastLine >= firstLine else { return false }

        var state = hiddenLinesState
        guard state.hide(firstLine...lastLine) else { return false }
        guard state.visibleLineCount(lineCount: lineCount) > 0 else { return false }

        adopt(hideState: state, for: document)
        return true
    }

    /// Unhides the hidden range(s) touching the caret's line.
    ///
    /// This is the "Unhide Lines" menu action: it removes the block that
    /// contains or immediately adjoins the selection, so a user who placed the
    /// caret next to a hidden block can reveal it without hunting for the
    /// margin symbol. With no hidden block at the caret it unhides the nearest
    /// hidden block in document order (the first one), keeping the command
    /// useful after a navigation that could not land inside hidden text.
    ///
    /// - Returns: `true` when a range was unhidden.
    @discardableResult
    func unhideSelectedLines() -> Bool {
        guard let document = boundDocument else { return false }
        var state = hiddenLinesState
        guard !state.isEmpty else { return false }

        let index = LineIndex(document.text)
        let selection = textView.selectedRange
        let length = document.textStorage.length
        let end = selection.length > 0
            ? min(length, NSMaxRange(selection)) - 1
            : min(max(0, selection.location), length)
        let firstLine = index.line(of: min(max(0, selection.location), end))
        let lastLine = index.line(of: max(0, end))

        let target = state.lineRanges.first {
            $0.lowerBound - 1 <= lastLine && $0.upperBound + 1 >= firstLine
        } ?? state.lineRanges.first
        guard let target else { return false }
        guard state.unhide(target) else { return false }
        adopt(hideState: state, for: document)
        return true
    }

    /// Unhides `range` (a margin-symbol click).
    @discardableResult
    func unhideLines(_ range: ClosedRange<Int>) -> Bool {
        guard let document = boundDocument else { return false }
        var state = hiddenLinesState
        guard state.unhide(range) else { return false }
        adopt(hideState: state, for: document)
        return true
    }

    /// Unhides every hidden range (View > Unhide Lines and the fallback that
    /// keeps a fully hidden document recoverable).
    ///
    /// - Returns: The number of ranges removed.
    @discardableResult
    func unhideAllLines() -> Int {
        guard let document = boundDocument else { return 0 }
        var state = hiddenLinesState
        let removed = state.unhideAll()
        guard removed > 0 else { return 0 }
        adopt(hideState: state, for: document)
        return removed
    }

    /// Writes `state` through to the per-document store, the persisted editor
    /// state, the cached character spans and the glyph hider.
    private func adopt(hideState state: HideLinesState, for document: DocumentModel) {
        hideStates[document.id] = state
        document.editorState.hiddenLinesState = state
        recomputeHiddenLineSpans(for: document)
        applyHiddenLineVisibility()
        ruler.needsDisplay = true
    }

    /// Adopts a document's persisted hidden lines when it is first bound.
    private func bindHiddenLines(for document: DocumentModel?) {
        guard let document else {
            hiddenLineCharacterRanges = []
            hiddenLineTextLineCount = 0
            applyHiddenLineVisibility()
            ruler.needsDisplay = true
            return
        }
        if hideStates[document.id] == nil {
            hideStates[document.id] = document.editorState.hiddenLinesState
        }
        recomputeHiddenLineSpans(for: document)
        applyHiddenLineVisibility()
        ruler.needsDisplay = true
    }

    /// Re-resolves line ranges into UTF-16 spans for the document's live text.
    /// A range that no longer names a line in this buffer (a stale session, or
    /// text removed under a hidden block) simply stops hiding anything.
    ///
    /// One `LineIndex` serves both the spans and the cached logical line count
    /// the gutter's renumbering and marker anchors need, so a draw pass never
    /// rescans the document.
    private func recomputeHiddenLineSpans(for document: DocumentModel) {
        let state = hideStates[document.id] ?? document.editorState.hiddenLinesState
        let index = LineIndex(document.text)
        hiddenLineTextLineCount = index.count
        hiddenLineCharacterRanges = state.lineRanges.compactMap {
            HideLinesVisibility.characterRange(for: $0, in: index)
        }
    }

    /// Hands the hide-lines mask to the glyph hider and relayouts when the
    /// effective hidden set changed. Folds keep their own mask in parallel.
    private func applyHiddenLineVisibility() {
        guard foldHider.setLineHiddenRanges(hiddenLineCharacterRanges) else { return }
        invalidateFoldLayout()
    }

    /// Selection-time visibility rules for hidden lines:
    ///
    /// - A bare caret never rests inside hidden text. Arrow keys, gutter clicks
    ///   and programmatic navigation clamp it to the nearest visible character.
    /// - A selection that fully covers a hidden range unhides it, so selecting
    ///   "across" a hidden block is the second way to reveal it (beside the
    ///   margin symbol).
    private func reconcileSelectionWithHiddenLines(_ selection: NSRange) {
        guard !hiddenLineCharacterRanges.isEmpty, let document = boundDocument else { return }

        if selection.length == 0 {
            let location = selection.location
            guard let hidden = hiddenLineCharacterRanges.first(where: {
                $0.location <= location && location < NSMaxRange($0)
            }) else { return }
            let target = hidden.location > 0 ? hidden.location - 1 : NSMaxRange(hidden)
            setMultiCaretState(MultiCaretState(caretAt: target))
            return
        }

        // Unhide every block the selection covers entirely. Line ranges are
        // re-derived against the live text so a stale range cannot match an
        // arbitrary offset.
        let selected = NSRange(location: selection.location, length: selection.length)
        var state = hiddenLinesState
        let index = LineIndex(document.text)
        var changed = false
        for range in state.lineRanges {
            guard let span = HideLinesVisibility.characterRange(for: range, in: index) else { continue }
            if selected.location <= span.location, NSMaxRange(selected) >= NSMaxRange(span) {
                changed = state.unhide(range) || changed
            }
        }
        guard changed else { return }
        adopt(hideState: state, for: document)
    }

    /// Remaps bookmarks across a text edit so their circles follow the lines.
    ///
    /// A whole-buffer replacement (reload, encoding change, command-driven
    /// replace) cannot be line-mapped meaningfully, so it revalidates the
    /// existing bookmarks against the new text instead of dropping them all.
    private func remapBookmarks(for edit: FoldTextEdit, oldLength: Int) {
        guard var model = bookmarkModel else { return }
        bookmarkRemapCount += 1
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
        // With no bookmarks there is nothing to move, so skip the O(document)
        // line math entirely; the model's text is re-synced lazily if a
        // bookmark is added later.
        let oldLength = storage.length - storage.changeInLength
        if let model = bookmarkModel, !model.isEmpty {
            remapBookmarks(for: edit, oldLength: oldLength)
        } else if bookmarkModel != nil {
            bookmarkModelTextIsStale = true
        }

        // Hidden lines are line-based, so their UTF-16 spans must be
        // recomputed against the edited text. With nothing hidden there is no
        // mask to keep valid and no layout to invalidate.
        if hasHiddenLines {
            recomputeHiddenLineSpans(for: document)
            applyHiddenLineVisibility()
        }

        guard let model = cachedFoldModel else { return }

        guard !model.foldState.isEmpty else {
            // No fold is collapsed, so visibility cannot change. Defer the
            // O(document) fold discovery until markers are next drawn.
            foldModelIsStale = true
            return
        }

        // Keep the collapsed set aligned with the edit, but defer the
        // O(document) fold discovery and the full layout invalidation until
        // the gutter or a visibility query actually needs them. Reading the
        // live per-document state (rather than the stale model) is what keeps
        // back-to-back edits — including multi-caret's per-caret replacements —
        // composing correctly before the next refresh.
        let state = foldStates[document.id] ?? document.foldState
        adoptFoldState(state.remapped(for: edit), for: document)
        foldModelIsStale = true
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
