import AppKit
import HexpadKit

/// N++ Incremental Search (Search > Incremental Search, Cmd+I).
///
/// A compact floating bar over the top of the focused editor. It owns its own
/// query and match list; it deliberately shares nothing with `FindBar`, so
/// opening it never rewrites the main Find query, history or match counter.
///
/// Highlighting is a lightweight in-viewport pass: matches come from the same
/// `SearchEngine.search` used by FindBar, but only the matches intersecting the
/// editor's visible character range get a temporary background attribute, so a
/// large document costs O(visible glyphs) per keystroke instead of O(matches).
final class IncrementalSearchBar: NSView, NSSearchFieldDelegate {

    var isVisible = false

    let searchField = NSSearchField()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    /// The focused pane's editor, injected by MainWindowController. The bar
    /// acts on the text view directly and never binds a document.
    weak var editorRef: EditorContainer?
    /// Called after `hide()` so the owner can relayout and restore focus.
    var onClose: (() -> Void)?

    private(set) var matches: [SearchMatch] = []
    private(set) var currentMatchIndex = -1
    private var lastQuery = ""
    /// Set while handling a field-editor command; Return must not be mistaken
    /// for a focus loss and tear the bar down.
    private var isHandlingCommand = false
    private var isHiding = false
    private var tabSelectionObserver: NSObjectProtocol?

    static let preferredHeight: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopObservingTabSelection()
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
        let gap: CGFloat = 2
        let buttonsWidth = buttonSize * 3 + gap * 2
        let height = max(18, bounds.height - 8)
        let fieldWidth = max(60, bounds.width - inset - buttonsWidth - inset - 4)
        searchField.frame = NSRect(x: inset, y: (bounds.height - height) / 2,
                                   width: fieldWidth, height: height)
        var x = bounds.width - inset - buttonsWidth
        for button in [previousButton, nextButton, closeButton] {
            button.frame = NSRect(x: x, y: (bounds.height - buttonSize) / 2,
                                  width: buttonSize, height: buttonSize)
            x += buttonSize + gap
        }
    }

    // MARK: - Show / hide

    /// Opens the bar with an optional seed (the editor selection). A seed is
    /// searched immediately so the first live highlight is not an extra
    /// keystroke away.
    func show(initialQuery: String = "") {
        isVisible = true
        isHidden = false
        isHiding = false
        searchField.stringValue = initialQuery
        matches = []
        currentMatchIndex = -1
        lastQuery = ""
        clearHighlights()
        startObservingTabSelection()
        if !initialQuery.isEmpty {
            performSearch()
        }
        needsLayout = true
    }

    /// Closes the bar and clears its highlights. Safe to call when hidden.
    func hide() {
        guard !isHiding else { return }
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
        stopObservingTabSelection()
        isHiding = false
        onClose?()
    }

    // MARK: - Searching

    /// Re-runs the incremental query against the focused editor. Called on
    /// every keystroke; the match list drives navigation while only visible
    /// matches are painted.
    func performSearch(select: Bool = true) {
        clearHighlights()
        guard isVisible, let textView = editorRef?.textView else {
            matches = []
            currentMatchIndex = -1
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
            return
        }
        matches = SearchEngine.search(textView.string, pattern: query, options: [])
        guard !matches.isEmpty else {
            currentMatchIndex = -1
            return
        }
        if currentMatchIndex < 0 || currentMatchIndex >= matches.count {
            currentMatchIndex = 0
        }
        applyHighlights(in: textView)
        if select {
            revealCurrentMatch(in: textView)
        }
    }

    /// Return: advance one match, wrapping at the end.
    func findNext() {
        guard isVisible, !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        if let textView = editorRef?.textView {
            revealCurrentMatch(in: textView)
        }
    }

    /// Shift+Return: step back one match, wrapping at the start.
    func findPrevious() {
        guard isVisible, !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        if let textView = editorRef?.textView {
            revealCurrentMatch(in: textView)
        }
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

    /// Paints only matches intersecting the visible character range. Matches
    /// that scroll into view after this pass are picked up by the next
    /// keystroke/navigation; preserving them across scrolling would need a
    /// viewport observer (deferred with the rest of highlight persistence).
    private func applyHighlights(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else { return }

        let visibleRect = textView.visibleRect
        let visibleRange: NSRange
        if visibleRect.isEmpty {
            // Offscreen (tests, or before the first layout): paint the whole
            // buffer rather than nothing.
            visibleRange = NSRange(location: 0, length: length)
        } else {
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
            visibleRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                        actualGlyphRange: nil)
        }

        let color = NSColor.findHighlightColor.withAlphaComponent(0.3)
        for match in matches where match.range.length > 0 {
            guard match.range.location != NSNotFound,
                  match.range.location + match.range.length <= length else { continue }
            guard NSIntersectionRange(match.range, visibleRange).length > 0 else { continue }
            layoutManager.addTemporaryAttributes([.backgroundColor: color],
                                                 forCharacterRange: match.range)
        }
    }

    private func clearHighlights() {
        guard let textView = editorRef?.textView,
              let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor,
                                              forCharacterRange: NSRange(location: 0, length: length))
    }

    // MARK: - Focus / tab lifecycle

    /// A tab switch invalidates the match ranges and the editor identity, so
    /// the bar closes rather than acting on the previous buffer.
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
        performSearch()
    }

    /// Hides when the field editor resigns focus (the user clicked into the
    /// document or another control). Command handling is excluded so Return
    /// does not close the bar it is meant to navigate.
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

    /// Escape reaches the bar as `cancelOperation` when the field editor or
    /// the bar itself holds focus.
    override func cancelOperation(_ sender: Any?) {
        hide()
    }

    override func keyDown(with event: NSEvent) {
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
