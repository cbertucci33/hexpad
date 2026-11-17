import AppKit
import HexpadKit

/// One document's Find All results: the identity needed to jump back to the
/// right editor, and the matches found in that buffer.
struct DocumentSearchGroup {
    let document: DocumentModel
    let matches: [DocumentMatch]

    /// Header title. File-backed documents show their path so two same-named
    /// files stay distinguishable; untitled buffers say so explicitly.
    var title: String {
        document.filePath?.path ?? "\(document.name) (untitled)"
    }
}

/// Find in Files panel. SearchEngine.searchInFiles shipped complete but had no
/// UI at all. Runs the search off the main thread and opens a hit in a tab.
///
/// Also hosts the open-document Find All results (Search > Find All in Current
/// Document / in All Opened Documents). Both modes share the table; file
/// results keep their one-row-per-file summary, document results add per-file
/// group headers with one row per match so every hit is individually
/// double-clickable. Fold/unfold of those groups is deferred.
final class FindInFilesWindowController: NSWindowController {

    private let chooseButton = NSButton(title: "Choose Folder...", target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: "No folder chosen")
    private let patternField = NSSearchField()
    private let replaceField = NSSearchField()
    private let regexCheckbox = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let caseCheckbox = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "Replace All in Files", target: nil, action: nil)
    private let resultsTable = NSTableView()
    private let resultsScrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")

    private enum Mode {
        case files
        case documents
    }
    private var mode: Mode = .files

    /// Row model for the document mode: one header per opened buffer followed
    /// by one row per match. Clicking a match row jumps to that exact range.
    private enum DocumentRow {
        case header(group: Int)
        case match(group: Int, index: Int)
    }

    private var directory: URL?
    private var results: [(URL, [SearchMatch])] = []
    /// Replacements performed per file by the last Replace All in Files run.
    /// Kept alongside the search hits so the table can show both counts.
    private var replaceCounts: [URL: Int] = [:]

    private(set) var documentGroups: [DocumentSearchGroup] = []
    private var documentRows: [DocumentRow] = []

    /// Called with the file URL and the match range to jump to in that file.
    var onOpenMatch: ((URL, NSRange) -> Void)?
    /// Called with the owning document and the exact match range for document
    /// results. The controller resolves the tab/group before scrolling.
    var onOpenDocumentMatch: ((DocumentModel, NSRange) -> Void)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Find in Files"
        window.minSize = NSSize(width: 420, height: 260)
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true

        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        chooseButton.bezelStyle = .rounded
        chooseButton.frame = NSRect(x: 12, y: 386, width: 130, height: 24)
        content.addSubview(chooseButton)

        folderLabel.font = NSFont.systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.frame = NSRect(x: 150, y: 390, width: 458, height: 16)
        folderLabel.autoresizingMask = [.width]
        content.addSubview(folderLabel)

        patternField.placeholderString = "Search pattern"
        patternField.frame = NSRect(x: 12, y: 352, width: 380, height: 24)
        patternField.target = self
        patternField.action = #selector(runSearch)
        patternField.autoresizingMask = [.width]
        content.addSubview(patternField)

        regexCheckbox.frame = NSRect(x: 400, y: 354, width: 70, height: 20)
        content.addSubview(regexCheckbox)
        caseCheckbox.frame = NSRect(x: 474, y: 354, width: 110, height: 20)
        caseCheckbox.autoresizingMask = [.minXMargin]
        content.addSubview(caseCheckbox)

        searchButton.target = self
        searchButton.action = #selector(runSearch)
        searchButton.keyEquivalent = "\r"
        searchButton.frame = NSRect(x: 590, y: 352, width: 20, height: 24)
        searchButton.autoresizingMask = [.minXMargin]
        content.addSubview(searchButton)

        replaceField.placeholderString = "Replace with"
        replaceField.frame = NSRect(x: 12, y: 320, width: 380, height: 24)
        replaceField.autoresizingMask = [.width]
        content.addSubview(replaceField)

        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllInFiles)
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.font = NSFont.systemFont(ofSize: 12)
        replaceAllButton.frame = NSRect(x: 400, y: 318, width: 170, height: 24)
        replaceAllButton.autoresizingMask = [.minXMargin]
        content.addSubview(replaceAllButton)

        resultsScrollView.frame = NSRect(x: 12, y: 34, width: 596, height: 272)
        resultsScrollView.autoresizingMask = [.width, .height]
        resultsScrollView.hasVerticalScroller = true
        resultsScrollView.borderType = .bezelBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit"))
        column.title = "Matches"
        column.width = 560
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.rowHeight = 32
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.target = self
        resultsTable.doubleAction = #selector(openSelected)
        resultsScrollView.documentView = resultsTable
        content.addSubview(resultsScrollView)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 12, y: 12, width: 596, height: 16)
        statusLabel.autoresizingMask = [.width]
        content.addSubview(statusLabel)
    }

    /// Inputs that only make sense for directory search. Document-result mode
    /// hides them and grows the table into the freed space.
    private var fileInputControls: [NSView] {
        [chooseButton, folderLabel, patternField, replaceField,
         regexCheckbox, caseCheckbox, searchButton, replaceAllButton]
    }

    private func setFileInputsVisible(_ visible: Bool) {
        for control in fileInputControls {
            control.isHidden = !visible
        }
        guard let content = window?.contentView else { return }
        let bottomInset: CGFloat = 34
        // File mode leaves the search/replace control band above the table;
        // document mode only needs the close/scroll/status band.
        let topInset: CGFloat = visible ? 114 : 10
        let height = max(80, content.bounds.height - bottomInset - topInset)
        resultsScrollView.frame = NSRect(x: 12, y: bottomInset,
                                         width: max(120, content.bounds.width - 24),
                                         height: height)
    }

    private func enterFilesMode() {
        guard mode != .files else { return }
        mode = .files
        window?.title = "Find in Files"
        setFileInputsVisible(true)
        resultsTable.reloadData()
    }

    /// Shows Find All results for open documents. `searchDescription` is the
    /// query echoed in the status line; the controller stays dumb about how the
    /// search was produced.
    func showDocumentResults(groups: [DocumentSearchGroup], searchDescription: String) {
        mode = .documents
        window?.title = "Search Results"
        setFileInputsVisible(false)

        documentGroups = groups
        documentRows = []
        for (groupIndex, group) in groups.enumerated() {
            documentRows.append(.header(group: groupIndex))
            for matchIndex in group.matches.indices {
                documentRows.append(.match(group: groupIndex, index: matchIndex))
            }
        }
        resultsTable.reloadData()

        let matchCount = groups.reduce(0) { $0 + $1.matches.count }
        if matchCount == 0 {
            statusLabel.stringValue = "No matches for \(searchDescription)"
        } else {
            statusLabel.stringValue = "\(matchCount) matches in \(groups.count) files for \(searchDescription)"
        }
    }

    /// Total hits currently listed in document mode. Used by app tests.
    var documentResultCount: Int {
        documentGroups.reduce(0) { $0 + $1.matches.count }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url
        folderLabel.stringValue = url.path
    }

    @objc private func runSearch() {
        enterFilesMode()
        guard let directory else {
            statusLabel.stringValue = "Choose a folder first"
            return
        }
        let pattern = patternField.stringValue
        guard !pattern.isEmpty else { return }

        var options: SearchOptions = []
        if regexCheckbox.state == .on { options.insert(.regex) }
        if caseCheckbox.state == .on { options.insert(.caseSensitive) }

        searchButton.isEnabled = false
        replaceAllButton.isEnabled = false
        statusLabel.stringValue = "Searching…"
        results = []
        replaceCounts = [:]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hits = SearchEngine.searchInFiles(directory: directory, pattern: pattern, options: options)
            DispatchQueue.main.async {
                guard let self else { return }
                self.results = hits
                self.resultsTable.reloadData()
                self.searchButton.isEnabled = true
                self.replaceAllButton.isEnabled = true
                let fileCount = hits.count
                let matchCount = hits.reduce(0) { $0 + $1.1.count }
                self.statusLabel.stringValue = fileCount == 0
                    ? "No matches"
                    : "\(matchCount) matches in \(fileCount) files"
            }
        }
    }

    /// Replaces every match under the chosen folder, then reports per-file
    /// replacement counts in the same table used for search hits.
    @objc private func replaceAllInFiles() {
        enterFilesMode()
        guard let directory else {
            statusLabel.stringValue = "Choose a folder first"
            return
        }
        let pattern = patternField.stringValue
        guard !pattern.isEmpty else { return }
        let replacement = replaceField.stringValue

        var options: SearchOptions = []
        if regexCheckbox.state == .on { options.insert(.regex) }
        if caseCheckbox.state == .on { options.insert(.caseSensitive) }

        searchButton.isEnabled = false
        replaceAllButton.isEnabled = false
        statusLabel.stringValue = "Replacing…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let replaced = SearchEngine.replaceInFiles(directory: directory, pattern: pattern,
                                                       replacement: replacement, options: options)
            DispatchQueue.main.async {
                guard let self else { return }
                self.searchButton.isEnabled = true
                self.replaceAllButton.isEnabled = true

                self.replaceCounts = Dictionary(replaced, uniquingKeysWith: { first, _ in first })
                // Keep existing hit rows where possible; add rows for files the
                // replace touched but a prior search may not have listed.
                var knownURLs = Set(self.results.map { $0.0 })
                for (url, _) in replaced where !knownURLs.contains(url) {
                    self.results.append((url, []))
                    knownURLs.insert(url)
                }
                self.resultsTable.reloadData()

                let total = replaced.reduce(0) { $0 + $1.1 }
                self.statusLabel.stringValue = replaced.isEmpty
                    ? "No matches to replace"
                    : "Replaced \(total) matches in \(replaced.count) files"
            }
        }
    }

    @objc private func openSelected() {
        let row = resultsTable.clickedRow
        switch mode {
        case .files:
            guard row >= 0, row < results.count else { return }
            let (url, matches) = results[row]
            guard let first = matches.first else { return }
            onOpenMatch?(url, first.range)
        case .documents:
            guard row >= 0, row < documentRows.count else { return }
            guard case .match(let groupIndex, let matchIndex) = documentRows[row] else { return }
            let group = documentGroups[groupIndex]
            guard group.matches.indices.contains(matchIndex) else { return }
            onOpenDocumentMatch?(group.document, group.matches[matchIndex].range)
        }
    }
}

extension FindInFilesWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch mode {
        case .files: return results.count
        case .documents: return documentRows.count
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard mode == .documents else { return true }
        guard row >= 0, row < documentRows.count else { return false }
        if case .header = documentRows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch mode {
        case .files:
            return fileResultView(row: row)
        case .documents:
            return documentResultView(row: row)
        }
    }

    private func fileResultView(row: Int) -> NSView? {
        guard row >= 0, row < results.count else { return nil }
        let (url, matches) = results[row]
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.font = NSFont.systemFont(ofSize: 11)
        let firstOffset = matches.first?.range.location ?? 0
        let summary: String
        if matches.isEmpty {
            summary = "\(replaceCounts[url] ?? 0) replaced"
        } else if let replaced = replaceCounts[url] {
            summary = "\(matches.count) match(es), \(replaced) replaced, first at offset \(firstOffset)"
        } else {
            summary = "\(matches.count) match(es), first at offset \(firstOffset)"
        }
        label.stringValue = "\(url.path)\n\(summary)"
        label.maximumNumberOfLines = 2
        return label
    }

    private func documentResultView(row: Int) -> NSView? {
        guard row >= 0, row < documentRows.count else { return nil }
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: 11)

        switch documentRows[row] {
        case .header(let groupIndex):
            let group = documentGroups[groupIndex]
            label.font = NSFont.boldSystemFont(ofSize: 11)
            label.stringValue = "\(group.title)  —  \(group.matches.count) match(es)"
            label.toolTip = group.document.filePath?.path
            label.maximumNumberOfLines = 1
        case .match(let groupIndex, let matchIndex):
            let match = documentGroups[groupIndex].matches[matchIndex]
            let preview = match.context.isEmpty ? "(blank line)" : match.context
            label.stringValue = "    \(match.line): \(preview)"
            label.toolTip = "Line \(match.line), column \(match.column): \(match.text)"
            label.maximumNumberOfLines = 1
        }
        return label
    }
}
