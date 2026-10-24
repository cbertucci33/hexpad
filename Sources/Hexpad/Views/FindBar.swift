import AppKit
import HexpadKit

class FindBar: NSView {
    
    var isVisible = false
    
    let searchField: NSSearchField
    private let replaceField: NSSearchField
    private let regexButton: NSButton
    private let literalButton: NSButton
    private let matchCountLabel: NSTextField
    private let findNextButton: NSButton
    private let findPrevButton: NSButton
    private let replaceButton: NSButton
    private let replaceAllButton: NSButton
    private let closeButton: NSButton
    
    private var currentMatchIndex = 0
    private var allMatches: [SearchMatch] = []
    private var searchOptions: SearchOptions = []
    
    // Observers for document changes
    private var documentChangeObserver: NSObjectProtocol?
    private var tabSelectionObserver: NSObjectProtocol?
    
    override init(frame frameRect: NSRect) {
        searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        replaceField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        regexButton = NSButton(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        literalButton = NSButton(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        matchCountLabel = NSTextField(labelWithString: "")
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
        
        matchCountLabel.font = font
        matchCountLabel.alignment = .center
        matchCountLabel.frame = NSRect(x: 512, y: yCenter, width: 80, height: 24)
        addSubview(matchCountLabel)
        
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
        closeButton.frame = NSRect(x: bounds.width - 28, y: yCenter, width: 24, height: 24)
        addSubview(closeButton)
    }
    
    // Single source of truth for visibility. The view stays in its parent
    // hierarchy the whole time; show()/hide() only flip the custom flag and
    // AppKit's isHidden together so they can never diverge. There is no
    // removeFromSuperview(): toggling is an infinite loop of add/remove, which
    // is what made Cmd+F die after the first close (nothing re-added the view).
    func show() {
        isVisible = true
        isHidden = false
    }

    func hide() {
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
    
    @objc private func searchTextChanged() {
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
    
    @objc private func findNextAction() {
        findNext()
    }
    
    @objc private func findPreviousAction() {
        findPrevious()
    }
    
    @objc private func replaceAction() {
        guard let doc = tabStore?.selectedDocument, !searchField.stringValue.isEmpty else { return }
        let matches = SearchEngine.search(doc.text, pattern: searchField.stringValue, options: searchOptions)
        guard currentMatchIndex < matches.count else { return }
        
        // Replace ONLY the current match, not all occurrences.
        let newContent = SearchEngine.replaceRange(in: doc.text, replacement: replaceField.stringValue, range: matches[currentMatchIndex].range)
        tabStore?.selectedDocument?.text = newContent
        
        // Re-run the find against the new content, then advance to the next match.
        performFind()
        findNext()
    }
    
    @objc private func replaceAllAction() {
        guard let doc = tabStore?.selectedDocument, !searchField.stringValue.isEmpty else { return }
        let matches = SearchEngine.search(doc.text, pattern: searchField.stringValue, options: searchOptions)
        let newContent = SearchEngine.replace(doc.text, pattern: searchField.stringValue, replacement: replaceField.stringValue, options: searchOptions)
        tabStore?.selectedDocument?.text = newContent
        performFind()
        matchCountLabel.stringValue = "\(matches.count) replaced"
    }
    
    @objc private func closeAction() {
        hide()
    }
    
    func performFind() {
        guard let doc = tabStore?.selectedDocument, let textView = editorContainer?.textView else { return }
        
        let pattern = searchField.stringValue
        allMatches = SearchEngine.search(doc.text, pattern: pattern, options: searchOptions)
        
        if pattern.isEmpty {
            // Empty query: show nothing
            matchCountLabel.stringValue = ""
            currentMatchIndex = 0
            return
        }
        
        if allMatches.isEmpty {
            matchCountLabel.stringValue = "No matches"
            currentMatchIndex = 0
            return
        }
        
        // Show "current of total" format
        matchCountLabel.stringValue = "\(currentMatchIndex + 1) of \(allMatches.count)"
        
        if currentMatchIndex >= allMatches.count {
            currentMatchIndex = 0
        }
        
        let match = allMatches[currentMatchIndex]
        textView.setSelectedRange(match.range)
        textView.scrollRangeToVisible(match.range)
    }
    
    func findNext() {
        guard !allMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % allMatches.count
        updateMatchDisplay()
    }
    
    func findPrevious() {
        guard !allMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + allMatches.count) % allMatches.count
        updateMatchDisplay()
    }
    
    private func updateMatchDisplay() {
        guard let textView = editorContainer?.textView else { return }
        let match = allMatches[currentMatchIndex]
        textView.setSelectedRange(match.range)
        textView.scrollRangeToVisible(match.range)
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
            self?.performFind()
        }
        
        // Observe document text changes
        documentChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DocumentModifiedDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !isFinding else { return }
            isFinding = true
            defer { isFinding = false }
            performFind()
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
