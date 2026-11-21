import AppKit
import HexpadKit

/// N++ Incremental Search (Search > Incremental Search, Cmd+I).
///
/// A compact floating bar over the top of the focused editor. It owns its own
/// query and match list; it deliberately shares nothing with `FindBar`, so
/// opening it never rewrites the main Find query, history or match counter.
final class IncrementalSearchBar: NSView, NSSearchFieldDelegate {

    var isVisible = false

    let searchField = NSSearchField()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    /// Missing pieces from the docs review (item 24): match-case, highlight-all
    /// and count toggles, an i/n counter, and an inline wrap message.
    var matchCaseButton: NSButton!
    var highlightAllButton: NSButton!
    var countButton: NSButton!
    var matchCountLabel: NSTextField!
    var wrapLabel: NSTextField!

    /// Aliases so callers/tests can use either the button or checkbox spelling.
    var matchCaseCheckbox: NSButton { matchCaseButton }
    var highlightAllCheckbox: NSButton { highlightAllButton }
    var countCheckbox: NSButton { countButton }
    var counterLabel: NSTextField { matchCountLabel }
    var wrapMessageLabel: NSTextField { wrapLabel }
    var wrapMessage: NSTextField { wrapLabel }

    /// The focused pane's editor, injected by MainWindowController. The bar
    /// acts on the text view directly and never binds a document.
    weak var editorRef: EditorContainer? {
        didSet {
            // A live pane switch re-injects the editor without a show/hide
            // cycle; move the scroll observation to the new clip view.
            guard isVisible else { return }
            startObservingViewport()
        }
    }
    /// Called after `hide()` so the owner can relayout and restore focus.
    var onClose: (() -> Void)?

    private(set) var matches: [SearchMatch] = []
    private(set) var currentMatchIndex = -1
    private var lastQuery = ""
    /// Debounce for live full-buffer searches in large documents, matching
    /// FindBar's policy so both search surfaces behave the same: documents
    /// over 1MB wait for a 150ms pause, smaller ones search immediately.
    private var pendingSearchWorkItem: DispatchWorkItem?
    private static let debounceSearchLength = 1_000_000
    private static let debounceInterval: TimeInterval = 0.15
    /// Set while handling a field-editor command; Return must not be mistaken
    /// for a focus loss and tear the bar down.
    private var isHandlingCommand = false
    private var isHiding = false
    private var tabSelectionObserver: NSObjectProtocol?
    private var viewportObservers: [NSObjectProtocol] = []
    /// Character range whose visible band has highlight-all temporary
    /// attributes painted. Scroll only repaints the band when the viewport
    /// moves outside it, which keeps scrolling O(viewport) and never rescans
    /// the document.
    private var highlightedRange: NSRange?
    private var pendingHighlightRefresh = false

    static let preferredHeight: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingSearchWorkItem?.cancel()
        stopObservingTabSelection()
        stopObservingViewport()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        searchField.placeholderString = "Incremental search"
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.delegate = self
        addSubview(searchField)

        matchCaseButton = NSButton(checkboxWithTitle: "Match case",
                                  target: self,
                                  action: #selector(matchCaseToggled))
        matchCaseButton.font = NSFont.systemFont(ofSize: 11)
        matchCaseButton.state = .off
        addSubview(matchCaseButton)

        highlightAllButton = NSButton(checkboxWithTitle: "Highlight all",
                                     target: self,
                                     action: #selector(highlightAllToggled))
        highlightAllButton.font = NSFont.systemFont(ofSize: 11)
        highlightAllButton.state = .on
        addSubview(highlightAllButton)

        countButton = NSButton(checkboxWithTitle: "Count",
                              target: self,
                              action: #selector(countToggled))
        countButton.font = NSFont.systemFont(ofSize: 11)
        countButton.state = .on
        addSubview(countButton)

        matchCountLabel = NSTextField(labelWithString: "")
        matchCountLabel.font = NSFont.systemFont(ofSize: 11)
        matchCountLabel.alignment = .center
        addSubview(matchCountLabel)

        wrapLabel = NSTextField(labelWithString: "")
        wrapLabel.font = NSFont.systemFont(ofSize: 11)
        wrapLabel.textColor = .secondaryLabelColor
        addSubview(wrapLabel)

        configure(previousButton, symbol: "chevron.up", action: #selector(findPreviousAction))
        previousButton.toolTip = "Previous match (Shift+Return)"
        configure(nextButton, symbol: "chevron.down", action: #selector(findNextAction))
        nextButton.toolTip = "Next match (Return)"
        configure(closeButton, symbol: "xmark", action: #selector(closeAction))
        closeButton.toolTip = "Close incremental search (Escape)"

        isHidden = true
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.target = self
        button.action = action
        addSubview(button)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 5
        let buttonSize: CGFloat = 22
        let gap: CGFloat = 4
        let buttonsWidth = buttonSize * 3 + gap * 2
        let height = max(18, bounds.height - 8)
        let cbWidths: [CGFloat] = [74, 86, 56]
        let cbTotal = cbWidths.reduce(0, +) + gap * CGFloat(cbWidths.count - 1)
        let counterWidth: CGFloat = 40
        let wrapWidth: CGFloat = 120
        let reserved = inset + cbTotal + gap + counterWidth + gap + wrapWidth + gap + buttonsWidth + inset + 4
        let fieldWidth = max(60, bounds.width - reserved)
        var x = inset
        searchField.frame = NSRect(x: x, y: (bounds.height - height) / 2,
                                   width: fieldWidth, height: height)
        x += fieldWidth + gap
        for (cb, w) in zip([matchCaseButton, highlightAllButton, countButton], cbWidths) {
            cb?.frame = NSRect(x: x, y: (bounds.height - height) / 2,
                               width: w, height: height)
            x += w + gap
        }
        matchCountLabel?.frame = NSRect(x: x, y: (bounds.height - height) / 2,
                                        width: counterWidth, height: height)
        x += counterWidth + gap
        wrapLabel?.frame = NSRect(x: x, y: (bounds.height - height) / 2,
                                  width: wrapWidth, height: height)
        x += wrapWidth + gap
        var bx = bounds.width - inset - buttonsWidth
        for button in [previousButton, nextButton, closeButton] {
            button.frame = NSRect(x: bx, y: (bounds.height - buttonSize) / 2,
                                  width: buttonSize, height: buttonSize)
            bx += buttonSize + gap
        }
    }

    // MARK: - Show / hide

    func show(initialQuery: String = "") {
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil
        isVisible = true
        isHidden = false
        isHiding = false
        searchField.stringValue = initialQuery
        matches = []
        currentMatchIndex = -1
        lastQuery = ""
        clearHighlights()
        startObservingTabSelection()
        startObservingViewport()
        if !initialQuery.isEmpty {
            performSearch()
        }
        updateCounter()
        needsLayout = true
    }

    func hide() {
        guard !isHiding else { return }
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil
        isHiding = true
        isVisible = false
        isHidden = true

        if searchField.currentEditor() != nil {
            searchField.window?.makeFirstResponder(nil)
        }
        clearHighlights()
        matches = []
        currentMatchIndex = -1
        lastQuery = ""
        wrapLabel?.stringValue = ""
        updateCounter()
        stopObservingTabSelection()
        stopObservingViewport()
        isHiding = false
        onClose?()
    }

    // MARK: - Searching

    func performSearch(select: Bool = true, debounce: Bool = false) {
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil

        let query = searchField.stringValue
        // An empty query clears immediately: there is no full pass to spare and
        // a pending debounce must not resurrect results after the field empties.
        var length = 0
        if let textView = editorRef?.textView {
            length = (textView.string as NSString).length
        }
        if debounce, !query.isEmpty, length > Self.debounceSearchLength {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingSearchWorkItem = nil
                self.performSearchNow(select: select)
            }
            pendingSearchWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval,
                                          execute: work)
            return
        }

        performSearchNow(select: select)
    }

    /// Synchronous search used by the debounce's trailing edge and by every
    /// non-typing caller (toggles, show, navigation).
    private func performSearchNow(select: Bool) {
        clearHighlights()
        guard isVisible, let textView = editorRef?.textView else {
            matches = []
            currentMatchIndex = -1
            updateCounter()
            return
        }
        let query = searchField.stringValue
        if query != lastQuery {
            currentMatchIndex = -1
            lastQuery = query
        }
        guard !query.isEmpty else {
            matches = []
            currentMatchIndex = -1
            wrapLabel?.stringValue = ""
            updateCounter()
            return
        }
        let options: SearchOptions = matchCaseButton?.state == .on ? .caseSensitive : []
        matches = SearchEngine.search(textView.string, pattern: query, options: options)
        guard !matches.isEmpty else {
            currentMatchIndex = -1
            wrapLabel?.stringValue = ""
            updateCounter()
            return
        }
        if currentMatchIndex < 0 || currentMatchIndex >= matches.count {
            currentMatchIndex = 0
        }
        if highlightAllButton?.state == .on {
            applyHighlights(in: textView)
        }
        if select {
            revealCurrentMatch(in: textView)
        }
        wrapLabel?.stringValue = ""
        updateCounter()
    }

    func findNext() {
        guard isVisible, !matches.isEmpty else { return }
        let wrapped = matches.count > 1 && currentMatchIndex == matches.count - 1
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        if let textView = editorRef?.textView {
            revealCurrentMatch(in: textView)
        }
        if wrapped {
            wrapLabel?.stringValue = "Wrapped to top"
        } else {
            wrapLabel?.stringValue = ""
        }
        updateCounter()
    }

    func findPrevious() {
        guard isVisible, !matches.isEmpty else { return }
        let wrapped = matches.count > 1 && currentMatchIndex == 0
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        if let textView = editorRef?.textView {
            revealCurrentMatch(in: textView)
        }
        if wrapped {
            wrapLabel?.stringValue = "Wrapped to bottom"
        } else {
            wrapLabel?.stringValue = ""
        }
        updateCounter()
    }

    private func revealCurrentMatch(in textView: NSTextView) {
        guard matches.indices.contains(currentMatchIndex) else { return }
        let length = (textView.string as NSString).length
        let match = matches[currentMatchIndex].range
        let location = min(max(0, match.location == NSNotFound ? 0 : match.location), length)
        let range = NSRange(location: location, length: min(match.length, length - location))
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    // MARK: - Highlighting

    /// Paints highlight-all for the visible band only. Temporary attributes are
    /// view state, so a document can be searched without rewriting its text.
    private func applyHighlights(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else {
            highlightedRange = nil
            return
        }

        let range = visibleCharacterRange(in: textView,
                                          layoutManager: layoutManager,
                                          container: container,
                                          length: length)
        paintHighlights(in: range, layoutManager: layoutManager, length: length)
        highlightedRange = range
    }

    /// Character range currently visible in the clip view, resolved through the
    /// layout manager rather than by guessing a character-per-pixel ratio.
    private func visibleCharacterRange(in textView: NSTextView,
                                       layoutManager: NSLayoutManager,
                                       container: NSTextContainer,
                                       length: Int) -> NSRange {
        let visibleRect = textView.visibleRect
        guard !visibleRect.isEmpty else { return NSRange(location: 0, length: length) }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    /// Paints the matches intersecting `range`, clamped to that band so a match
    /// spanning the document never makes one paint pass O(document).
    private func paintHighlights(in range: NSRange,
                                 layoutManager: NSLayoutManager,
                                 length: Int) {
        let color = NSColor.findHighlightColor.withAlphaComponent(0.3)
        for match in matches where match.range.length > 0 {
            guard match.range.location != NSNotFound,
                  match.range.location + match.range.length <= length else { continue }
            let paintedRange = NSIntersectionRange(match.range, range)
            guard paintedRange.length > 0 else { continue }
            layoutManager.addTemporaryAttributes([.backgroundColor: color],
                                                 forCharacterRange: paintedRange)
        }
    }

    /// Repaints only the band that scrolled into view. Repainting every band the
    /// viewport passes over is what keeps the highlights from going stale; the
    /// contained check skips pixel-sized scrolls inside the painted band.
    private func refreshHighlightsForVisibleBand() {
        guard isVisible,
              highlightAllButton?.state == .on,
              !matches.isEmpty,
              let textView = editorRef?.textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else {
            highlightedRange = nil
            return
        }

        let range = visibleCharacterRange(in: textView,
                                          layoutManager: layoutManager,
                                          container: container,
                                          length: length)
        if let painted = highlightedRange,
           painted.location <= range.location,
           range.location + range.length <= painted.location + painted.length {
            return
        }
        // Drop any stale band attributes before repainting the newly visible
        // band, including partial matches left by the previous position.
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        paintHighlights(in: range, layoutManager: layoutManager, length: length)
        highlightedRange = range
    }

    private func clearHighlights() {
        highlightedRange = nil
        guard let textView = editorRef?.textView,
              let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor,
                                              forCharacterRange: NSRange(location: 0, length: length))
    }

    private func updateCounter() {
        guard let label = matchCountLabel else { return }
        guard countButton?.state == .on else {
            label.stringValue = ""
            label.isHidden = true
            return
        }
        label.isHidden = false
        if matches.isEmpty || currentMatchIndex < 0 {
            label.stringValue = ""
        } else {
            label.stringValue = "\(currentMatchIndex + 1)/\(matches.count)"
        }
    }

    // MARK: - Toggles

    @objc private func matchCaseToggled() {
        performSearch()
    }

    @objc private func highlightAllToggled() {
        guard let textView = editorRef?.textView else { return }
        if highlightAllButton.state == .on {
            // Re-run to repaint highlights for the current match list.
            applyHighlights(in: textView)
        } else {
            clearHighlights()
        }
    }

    @objc private func countToggled() {
        updateCounter()
    }

    // MARK: - Focus / tab lifecycle

    /// Watches the focused editor's clip view the standard AppKit way: the clip
    /// posts bounds changes, and each one means `visibleRect` moved. Updates are
    /// coalesced to one run-loop turn so a trackpad flick does not repaint per
    /// pixel.
    private func startObservingViewport() {
        stopObservingViewport()
        guard let clip = editorRef?.scrollView.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true

        let center = NotificationCenter.default
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            viewportObservers.append(center.addObserver(
                forName: name,
                object: clip,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleViewportHighlightRefresh()
            })
        }
    }

    private func stopObservingViewport() {
        viewportObservers.forEach { NotificationCenter.default.removeObserver($0) }
        viewportObservers.removeAll()
        pendingHighlightRefresh = false
    }

    private func scheduleViewportHighlightRefresh() {
        guard isVisible, !pendingHighlightRefresh,
              highlightAllButton?.state == .on, !matches.isEmpty else { return }
        pendingHighlightRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingHighlightRefresh = false
            self.refreshHighlightsForVisibleBand()
        }
    }

    private func startObservingTabSelection() {
        guard tabSelectionObserver == nil else { return }
        tabSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TabStoreSelectedIndexDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.hide()
        }
    }

    private func stopObservingTabSelection() {
        if let observer = tabSelectionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        tabSelectionObserver = nil
    }

    // MARK: - Field events

    func controlTextDidChange(_ obj: Notification) {
        performSearch(debounce: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isVisible, !isHiding, !isHandlingCommand else { return }
        hide()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            isHandlingCommand = true
            defer { isHandlingCommand = false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                findPrevious()
            } else {
                findNext()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            isHandlingCommand = true
            defer { isHandlingCommand = false }
            hide()
            return true
        }
        return false
    }

    override func cancelOperation(_ sender: Any?) {
        hide()
    }

    override func keyDown(with event: NSEvent) {
        // F3 (and Shift+F3) navigate matches while the bar has focus.
        if event.keyCode == 99 { // F3
            if event.modifierFlags.contains(.shift) { findPrevious() } else { findNext() }
            return
        }
        switch event.characters ?? "" {
        case "\r":
            if event.modifierFlags.contains(.shift) { findPrevious() } else { findNext() }
        case "\u{001B}":
            hide()
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func findNextAction() { findNext() }
    @objc private func findPreviousAction() { findPrevious() }
    @objc private func closeAction() { hide() }
}