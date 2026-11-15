import AppKit
import HexpadKit

class FindBar: NSView, NSSearchFieldDelegate {
    
    var isVisible = false
    
    let searchField: NSSearchField
    private let replaceField: NSSearchField
    private let regexButton: NSButton
    private let literalButton: NSButton
    private let wholeWordButton: NSButton
    private let inSelectionButton: NSButton
    let matchCountLabel: NSTextField
    private let wrapButton: NSButton
    private let findNextButton: NSButton
    private let findPrevButton: NSButton
    private let replaceButton: NSButton
    private let replaceAllButton: NSButton
    private let closeButton: NSButton
    
    private var currentMatchIndex = 0
    private var allMatches: [SearchMatch] = []
    // Wrap is on by default (historical behaviour) but now switchable; the
    // other options were previously unreachable from the UI at all.
    private var searchOptions: SearchOptions = [.wrapAround]
    private var lastQuery = ""

    /// Original selection captured when "In selection" starts, so selecting a
    /// match does not shrink the search scope to that match on the next pass.
    private var selectionScope: NSRange?
    /// The range we last selected to show a match. Used to tell "the user
    /// selected this" apart from "the find bar selected this".
    private var lastSelectedMatchRange: NSRange?

    // Notepad++-style find history. Newest first; cap at searchHistoryLimit.
    private static let searchHistoryKey = "HexpadFindSearchHistory"
    private static let searchHistoryLimit = 10
    private var searchHistory: [String] = []
    private var historyIndex: Int?
    
    // Observers for document changes
    private var documentChangeObserver: NSObjectProtocol?
    private var tabSelectionObserver: NSObjectProtocol?
    
    override init(frame frameRect: NSRect) {
        searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        replaceField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        regexButton = NSButton(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        literalButton = NSButton(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        wholeWordButton = NSButton(frame: NSRect(x: 0, y: 0, width: 82, height: 24))
        inSelectionButton = NSButton(frame: NSRect(x: 0, y: 0, width: 86, height: 24))
        matchCountLabel = NSTextField(labelWithString: "")
        wrapButton = NSButton(frame: NSRect(x: 0, y: 0, width: 62, height: 24))
        findNextButton = NSButton(frame: NSRect(x: 0, y: 0, width: 70, height: 24))
        findPrevButton = NSButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        replaceButton = NSButton(frame: NSRect(x: 0, y: 0, width: 70, height: 24))
        replaceAllButton = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        closeButton = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        
        let font = NSFont.systemFont(ofSize: 12)
        let yCenter: CGFloat = 6
        
        searchField.placeholderString = "Find..."
        searchField.font = font
        searchField.frame = NSRect(x: 8, y: yCenter, width: 180, height: 24)
        searchField.target = self
        searchField.action = #selector(searchTextChanged)
        // While typing, the field editor (firstResponder) consumes Enter/Escape
        // before our keyDown ever runs; the delegate sees them first.
        searchField.delegate = self
        addSubview(searchField)
        
        replaceField.placeholderString = "Replace..."
        replaceField.font = font
        replaceField.frame = NSRect(x: 196, y: yCenter, width: 180, height: 24)
        replaceField.target = self
        replaceField.action = #selector(replaceTextChanged)
        addSubview(replaceField)
        
        literalButton.title = "Literal"
        literalButton.bezelStyle = .rounded
        literalButton.font = font
        literalButton.state = .on
        literalButton.target = self
        literalButton.action = #selector(searchModeToggled)
        literalButton.frame = NSRect(x: 384, y: yCenter, width: 60, height: 24)
        addSubview(literalButton)
        
        regexButton.title = "Regex"
        regexButton.bezelStyle = .rounded
        regexButton.font = font
        regexButton.state = .off
        regexButton.target = self
        regexButton.action = #selector(searchModeToggled)
        regexButton.frame = NSRect(x: 448, y: yCenter, width: 60, height: 24)
        addSubview(regexButton)
        
        wholeWordButton.title = "Whole Word"
        wholeWordButton.bezelStyle = .rounded
        wholeWordButton.font = font
        wholeWordButton.state = .off
        wholeWordButton.target = self
        wholeWordButton.action = #selector(wholeWordToggled)
        addSubview(wholeWordButton)
        
        inSelectionButton.title = "Selection"
        inSelectionButton.toolTip = "Search only inside the current selection"
        inSelectionButton.bezelStyle = .rounded
        inSelectionButton.font = font
        inSelectionButton.state = .off
        inSelectionButton.target = self
        inSelectionButton.action = #selector(inSelectionToggled)
        addSubview(inSelectionButton)
        
        matchCountLabel.font = font
        matchCountLabel.alignment = .center
        addSubview(matchCountLabel)

        wrapButton.title = "Wrap"
        wrapButton.bezelStyle = .rounded
        wrapButton.font = font
        wrapButton.state = .on
        wrapButton.target = self
        wrapButton.action = #selector(wrapToggled)
        addSubview(wrapButton)
        
        findPrevButton.title = "Prev"
        findPrevButton.bezelStyle = .rounded
        findPrevButton.font = font
        findPrevButton.target = self
        findPrevButton.action = #selector(findPreviousAction)
        findPrevButton.frame = NSRect(x: 596, y: yCenter, width: 60, height: 24)
        addSubview(findPrevButton)
        
        findNextButton.title = "Next"
        findNextButton.bezelStyle = .rounded
        findNextButton.font = font
        findNextButton.target = self
        findNextButton.action = #selector(findNextAction)
        findNextButton.frame = NSRect(x: 660, y: yCenter, width: 60, height: 24)
        addSubview(findNextButton)
        
        replaceButton.title = "Replace"
        replaceButton.bezelStyle = .rounded
        replaceButton.font = font
        replaceButton.target = self
        replaceButton.action = #selector(replaceAction)
        replaceButton.frame = NSRect(x: 724, y: yCenter, width: 70, height: 24)
        addSubview(replaceButton)
        
        replaceAllButton.title = "Replace All"
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.font = font
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllAction)
        replaceAllButton.frame = NSRect(x: 800, y: yCenter, width: 80, height: 24)
        addSubview(replaceAllButton)
        
        closeButton.title = "×"
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 14)
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        addSubview(closeButton)

        // Children are positioned in layout(), never from init-time bounds:
        // the bar is created with an empty frame, so anything computed here
        // would be baked at zero. Every child tracks width so a resize keeps
        // the row usable instead of stranding controls off the right edge.
        for child in subviews {
            child.autoresizingMask.insert(.maxXMargin)
        }
        closeButton.autoresizingMask = [.minXMargin, .maxYMargin]

        // The bar exists from launch but must not paint until asked for.
        // isHidden=false at a zero frame used to leave a phantom bar whose
        // custom isVisible flag disagreed with AppKit state from birth.
        isHidden = true

        loadSearchHistory()
    }

    /// Height the bar needs at a given width: one row when there is room,
    /// two compact rows when the window is narrow. Adding whole-word and
    /// selection controls pushed the single-row minimum past 1100pt.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        width < 1180 ? 62 : 36
    }

    /// Single place that positions the control row from the real bounds width.
    /// Runs on every bounds change (init frame, toggle, window resize).
    override func layout() {
        super.layout()
        let h: CGFloat = 24
        let closeWidth: CGFloat = 24
        let rightInset: CGFloat = 4
        let twoRows = bounds.width < 1180
        let row1Y: CGFloat = twoRows ? bounds.height - h - 4 : 6
        let row2Y: CGFloat = 6

        let closeX = max(8, bounds.width - rightInset - closeWidth)
        closeButton.frame = NSRect(x: closeX, y: row1Y, width: closeWidth, height: h)

        if twoRows {
            // Row 1: the query and replacement fields plus close.
            let fieldWidth = max(120, (closeX - 24) / 2)
            searchField.frame = NSRect(x: 8, y: row1Y, width: fieldWidth, height: h)
            replaceField.frame = NSRect(x: 12 + fieldWidth, y: row1Y, width: fieldWidth, height: h)
            // Row 2: every other control left to right.
            var x: CGFloat = 8
            for (control, width) in [(literalButton, 58), (regexButton, 58), (wholeWordButton, 82),
                                     (inSelectionButton, 86), (wrapButton, 62), (matchCountLabel, 80),
                                     (findPrevButton, 56), (findNextButton, 56),
                                     (replaceButton, 70), (replaceAllButton, 80)] as [(NSView, CGFloat)] {
                control.frame = NSRect(x: x, y: row2Y, width: width, height: h)
                x += width + 6
            }
            return
        }

        searchField.frame = NSRect(x: 8, y: row1Y, width: 180, height: h)
        replaceField.frame = NSRect(x: 196, y: row1Y, width: 180, height: h)
        literalButton.frame = NSRect(x: 384, y: row1Y, width: 58, height: h)
        regexButton.frame = NSRect(x: 446, y: row1Y, width: 58, height: h)
        wholeWordButton.frame = NSRect(x: 508, y: row1Y, width: 82, height: h)
        inSelectionButton.frame = NSRect(x: 594, y: row1Y, width: 86, height: h)
        wrapButton.frame = NSRect(x: 684, y: row1Y, width: 62, height: h)
        matchCountLabel.frame = NSRect(x: 750, y: row1Y, width: 80, height: h)
        findPrevButton.frame = NSRect(x: 834, y: row1Y, width: 56, height: h)
        findNextButton.frame = NSRect(x: 894, y: row1Y, width: 56, height: h)

        // Replace controls hug the close button on the right.
        let replaceAllX = max(8, closeX - 84)
        let replaceX = max(8, replaceAllX - 74)
        replaceAllButton.frame = NSRect(x: replaceAllX, y: row1Y, width: 80, height: h)
        replaceButton.frame = NSRect(x: replaceX, y: row1Y, width: 70, height: h)
    }
    
    // Single source of truth for visibility. The view stays in its parent
    // hierarchy the whole time; show()/hide() only flip the custom flag and
    // AppKit's isHidden together so they can never diverge. There is no
    // removeFromSuperview(): toggling is an infinite loop of add/remove, which
    // is what made Cmd+F die after the first close (nothing re-added the view).
    func show() {
        isVisible = true
        isHidden = false
        selectionScope = nil
        lastSelectedMatchRange = nil
        historyIndex = nil
        // Reopen with the last query, like Notepad++ does. MainWindowController
        // still overwrites this when the editor has a fresh selection to seed.
        if searchField.stringValue.isEmpty, let last = searchHistory.first {
            searchField.stringValue = last
        }
        if !searchField.stringValue.isEmpty {
            performFind()
        }
    }

    func hide() {
        commitSearchHistory()
        clearHighlights()
        isVisible = false
        isHidden = true
        NotificationCenter.default.post(name: NSNotification.Name("FindBarClosed"), object: nil)
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.characters ?? ""
        if chars == "\r" {
            // Enter: advance to next match (Shift+Enter handled by the branch below).
            if event.modifierFlags.contains(.shift) {
                findPrevious()
            } else {
                findNext()
            }
        } else if chars == "\u{001B}" {
            // Escape key
            hide()
        }
    }

    /// Escape while the search field (or any child) has focus arrives here as
    /// cancelOperation, not as keyDown, because the field editor swallows the
    /// key first. Without this the bar could not be closed by keyboard at all.
    override func cancelOperation(_ sender: Any?) {
        hide()
    }
    
    @objc private func searchTextChanged() {
        historyIndex = nil
        // Enter fires this action too, after the delegate already advanced a
        // match. Skip the redundant re-find when the query did not change so
        // one Enter press advances exactly one match instead of two.
        if searchField.stringValue == lastQuery, !allMatches.isEmpty {
            commitSearchHistory()
            return
        }
        performFind()
    }
    
    @objc private func replaceTextChanged() {
        // No action needed
    }
    
    @objc private func searchModeToggled() {
        if regexButton.state == .on {
            searchOptions.insert(.regex)
            literalButton.state = .off
        } else {
            searchOptions.remove(.regex)
            literalButton.state = .on
        }
        performFind()
    }

    @objc private func wrapToggled() {
        if wrapButton.state == .on {
            searchOptions.insert(.wrapAround)
        } else {
            searchOptions.remove(.wrapAround)
        }
    }
    
    @objc private func wholeWordToggled() {
        if wholeWordButton.state == .on {
            searchOptions.insert(.wholeWord)
        } else {
            searchOptions.remove(.wholeWord)
        }
        performFind()
    }
    
    @objc private func inSelectionToggled() {
        if inSelectionButton.state == .on {
            searchOptions.insert(.inSelection)
        } else {
            searchOptions.remove(.inSelection)
        }
        // Re-capture from the current editor selection the next time find runs.
        selectionScope = nil
        lastSelectedMatchRange = nil
        performFind()
    }
    
    @objc private func findNextAction() {
        findNext()
    }
    
    @objc private func findPreviousAction() {
        findPrevious()
    }
    
    @objc private func replaceAction() {
        guard let doc = tabStore?.selectedDocument, !searchField.stringValue.isEmpty else { return }
        commitSearchHistory()
        let scope = activeSearchScope()
        let matches = SearchEngine.search(doc.text, pattern: searchField.stringValue,
                                          options: searchOptions, range: scope)
        guard currentMatchIndex < matches.count else { return }
        
        // Replace ONLY the current match, not all occurrences. Mutating the
        // document's shared storage updates the visible editor in place and
        // registers undo, unlike the old model-only string assignment.
        doc.replaceCharacters(in: matches[currentMatchIndex].range, with: replaceField.stringValue)
        
        // Re-run the find against the new content, then advance to the next match.
        performFind()
        findNext()
    }
    
    @objc private func replaceAllAction() {
        guard let doc = tabStore?.selectedDocument, !searchField.stringValue.isEmpty else { return }
        commitSearchHistory()
        let scope = activeSearchScope()
        let matches = SearchEngine.search(doc.text, pattern: searchField.stringValue,
                                          options: searchOptions, range: scope)
        let newContent = SearchEngine.replace(doc.text, pattern: searchField.stringValue,
                                              replacement: replaceField.stringValue,
                                              options: searchOptions, range: scope)
        // Replace all goes through the shared storage as one undoable edit, so
        // the editor reflects it immediately instead of silently keeping the
        // old visible text.
        doc.replaceAllText(with: newContent)
        performFind()
        matchCountLabel.stringValue = "\(matches.count) replaced"
    }
    
    @objc private func closeAction() {
        hide()
    }
    
    func performFind(select: Bool = true) {
        guard let doc = tabStore?.selectedDocument, let textView = editorContainer?.textView else { return }

        let pattern = searchField.stringValue
        // A new query starts at the first match; navigation/edits keep the
        // current index so Replace still targets the match the user sees.
        if pattern != lastQuery {
            currentMatchIndex = 0
        }
        lastQuery = pattern
        let scope = activeSearchScope()
        allMatches = SearchEngine.search(doc.text, pattern: pattern, options: searchOptions, range: scope)

        if pattern.isEmpty {
            // Empty query: show nothing
            matchCountLabel.stringValue = ""
            currentMatchIndex = 0
            clearHighlights()
            return
        }

        if allMatches.isEmpty {
            // Distinguish a broken regex from an honest zero-result search:
            // SearchEngine silently degrades invalid regex to a literal pass.
            if searchOptions.contains(.regex), !SearchEngine.isValidRegex(pattern) {
                matchCountLabel.stringValue = "Bad regex"
            } else {
                matchCountLabel.stringValue = "No matches"
            }
            currentMatchIndex = 0
            clearHighlights()
            return
        }

        // Clamp BEFORE labelling so the counter can never read "7 of 3"
        // after an edit shrank the match list.
        if currentMatchIndex >= allMatches.count {
            currentMatchIndex = 0
        }
        matchCountLabel.stringValue = "\(currentMatchIndex + 1) of \(allMatches.count)"
        applyHighlights()

        // Selection is only applied on explicit navigation/toggle so that
        // typing in the document does not yank the caret to a match.
        guard select else { return }
        let match = allMatches[currentMatchIndex]
        textView.setSelectedRange(match.range)
        textView.scrollRangeToVisible(match.range)
        lastSelectedMatchRange = match.range
    }

    /// Returns the selection captured for "In selection", or nil when the
    /// option is off / there was no selection to begin with (Notepad++ falls
    /// back to the whole document in that case).
    ///
    /// A selection equal to the match we last highlighted is our own doing, not
    /// a new user scope, so it must not shrink the search region.
    private func activeSearchScope() -> NSRange? {
        guard searchOptions.contains(.inSelection), let textView = editorContainer?.textView else {
            return nil
        }
        let selected = textView.selectedRange
        if let last = lastSelectedMatchRange, NSEqualRanges(selected, last) {
            return selectionScope
        }
        if selected.length > 0 {
            selectionScope = selected
        }
        return selectionScope
    }

    // MARK: - Match highlighting

    /// Paints every match with a temporary background attribute. Temporary
    /// attributes belong to the layout manager, not the document, so they are
    /// never saved and never pollute undo/syntax colouring.
    private func applyHighlights() {
        guard isVisible,
              let textView = editorContainer?.textView,
              let layoutManager = textView.layoutManager else {
            clearHighlights()
            return
        }
        clearHighlights()
        let length = (textView.string as NSString).length
        guard length > 0 else { return }

        let color = NSColor.findHighlightColor.withAlphaComponent(0.25)
        for match in allMatches where match.range.length > 0 {
            guard match.range.location != NSNotFound,
                  match.range.location + match.range.length <= length else { continue }
            layoutManager.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: match.range)
        }
    }

    private func clearHighlights() {
        guard let textView = editorContainer?.textView,
              let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor,
                                               forCharacterRange: NSRange(location: 0, length: length))
    }

    // MARK: - Search history

    private func loadSearchHistory() {
        searchHistory = Array((UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? [])
            .prefix(Self.searchHistoryLimit))
    }

    private func commitSearchHistory() {
        let query = searchField.stringValue
        guard !query.isEmpty else { return }
        searchHistory.removeAll { $0 == query }
        searchHistory.insert(query, at: 0)
        if searchHistory.count > Self.searchHistoryLimit {
            searchHistory.removeLast(searchHistory.count - Self.searchHistoryLimit)
        }
        UserDefaults.standard.set(searchHistory, forKey: Self.searchHistoryKey)
        historyIndex = nil
    }

    /// Up/Down cycle through recent queries. Starting from an empty field
    /// loads the newest; Down past the newest clears the field again.
    private func moveInHistory(up: Bool) {
        guard !searchHistory.isEmpty else { return }
        if let index = historyIndex {
            if up {
                guard index + 1 < searchHistory.count else { NSSound.beep(); return }
                historyIndex = index + 1
                searchField.stringValue = searchHistory[index + 1]
            } else {
                if index > 0 {
                    historyIndex = index - 1
                    searchField.stringValue = searchHistory[index - 1]
                } else {
                    historyIndex = nil
                    searchField.stringValue = ""
                }
            }
        } else {
            // From an empty field either arrow opens history at the newest
            // entry; Up then walks older, Down walks newer / clears.
            guard searchField.stringValue.isEmpty else { return }
            historyIndex = 0
            searchField.stringValue = searchHistory[0]
        }
        performFind()
    }
    
    func findNext() {
        guard !allMatches.isEmpty else { return }
        commitSearchHistory()
        if !searchOptions.contains(.wrapAround), currentMatchIndex == allMatches.count - 1 {
            NSSound.beep()
            updateMatchDisplay()
            return
        }
        currentMatchIndex = (currentMatchIndex + 1) % allMatches.count
        updateMatchDisplay()
    }
    
    func findPrevious() {
        guard !allMatches.isEmpty else { return }
        commitSearchHistory()
        if !searchOptions.contains(.wrapAround), currentMatchIndex == 0 {
            NSSound.beep()
            updateMatchDisplay()
            return
        }
        currentMatchIndex = (currentMatchIndex - 1 + allMatches.count) % allMatches.count
        updateMatchDisplay()
    }
    
    private func updateMatchDisplay() {
        guard let textView = editorContainer?.textView else { return }
        let match = allMatches[currentMatchIndex]
        textView.setSelectedRange(match.range)
        textView.scrollRangeToVisible(match.range)
        lastSelectedMatchRange = match.range
        matchCountLabel.stringValue = "\(currentMatchIndex + 1) of \(allMatches.count)"
    }
    
    func setupObservers() {
        // Observe tab selection changes. Must listen to specific names only:
        // forName: nil catches every notification, including the selection-change
        // notifications performFind itself triggers, causing re-entrant performFind
        // recursion and a stack-overflow crash.
        tabSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TabStoreSelectedIndexDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.selectionScope = nil
            self?.lastSelectedMatchRange = nil
            self?.performFind()
        }
        
        // Observe document text changes. Programmatic edits post this from
        // DocumentModel; typing is forwarded by MainWindowController's text
        // view delegate, so the count and highlights stay live either way.
        documentChangeObserver = NotificationCenter.default.addObserver(
            forName: DocumentModel.textDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !isFinding else { return }
            isFinding = true
            defer { isFinding = false }
            // Recompute counts without stealing the caret: the user is mid-edit.
            performFind(select: false)
        }
    }
    
    deinit {
        if let observer = documentChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = tabSelectionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // Enter/Shift+Enter while the search FIELD has focus are consumed by its
    // field editor (NSTextView), which consults this delegate BEFORE inserting
    // a newline — keyDown on the bar never sees them in that focus state.
    // This is the only reliable Enter hook for the typed-into case.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitSearchHistory()
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                findPrevious()
            } else {
                findNext()
            }
            return true
        }
        // Up/Down browse recent queries while the field is empty; once cycling
        // has started they keep moving through history. Any text edit resets it.
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            if searchField.stringValue.isEmpty || historyIndex != nil {
                moveInHistory(up: true)
                return true
            }
            return false
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            if searchField.stringValue.isEmpty || historyIndex != nil {
                moveInHistory(up: false)
                return true
            }
            return false
        }
        return false
    }
    
    func controlTextDidChange(_ obj: Notification) {
        // NSSearchField's action alone is not fired for every keystroke, so
        // hook the field editor for live counts and highlights while typing.
        historyIndex = nil
        performFind()
    }
    
    // Direct references injected by MainWindowController. The responder-chain walks
    // are fallbacks only: sibling views (EditorContainer) never appear in the
    // responder chain, so without injection editorContainer resolved nil forever.
    weak var tabStoreRef: TabStore?
    weak var editorRef: EditorContainer?
    private var isFinding = false
    
    var tabStore: TabStore? {
        if let tabStoreRef { return tabStoreRef }
        var responder: NSResponder? = self.nextResponder
        while let r = responder {
            if let mc = r as? MainWindowController {
                return mc.tabStore
            }
            responder = r.nextResponder
        }
        return nil
    }
    
    var editorContainer: EditorContainer? {
        if let editorRef { return editorRef }
        // Sibling views are not in the responder chain; walk the view hierarchy as fallback.
        if let root = window?.contentView {
            if let ec = findEditorContainer(in: root) { return ec }
        }
        return nil
    }
    
    private func findEditorContainer(in view: NSView) -> EditorContainer? {
        if let ec = view as? EditorContainer { return ec }
        for sub in view.subviews {
            if let ec = findEditorContainer(in: sub) { return ec }
        }
        return nil
    }
}
