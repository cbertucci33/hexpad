import AppKit
import HexpadKit

/// Find in Files panel. SearchEngine.searchInFiles shipped complete but had no
/// UI at all. Runs the search off the main thread and opens a hit in a tab.
final class FindInFilesWindowController: NSWindowController {

    private let folderLabel = NSTextField(labelWithString: "No folder chosen")
    private let patternField = NSSearchField()
    private let regexCheckbox = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let caseCheckbox = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let resultsTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var directory: URL?
    private var results: [(URL, [SearchMatch])] = []

    /// Called with the file URL and the match range to jump to in that file.
    var onOpenMatch: ((URL, NSRange) -> Void)?

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

        let chooseButton = NSButton(title: "Choose Folder...", target: self, action: #selector(chooseFolder))
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

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 34, width: 596, height: 306))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

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
        scroll.documentView = resultsTable
        content.addSubview(scroll)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 12, y: 12, width: 596, height: 16)
        statusLabel.autoresizingMask = [.width]
        content.addSubview(statusLabel)
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
        statusLabel.stringValue = "Searching…"
        results = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hits = SearchEngine.searchInFiles(directory: directory, pattern: pattern, options: options)
            DispatchQueue.main.async {
                guard let self else { return }
                self.results = hits
                self.resultsTable.reloadData()
                self.searchButton.isEnabled = true
                let fileCount = hits.count
                let matchCount = hits.reduce(0) { $0 + $1.1.count }
                self.statusLabel.stringValue = fileCount == 0
                    ? "No matches"
                    : "\(matchCount) matches in \(fileCount) files"
            }
        }
    }

    @objc private func openSelected() {
        let row = resultsTable.clickedRow
        guard row >= 0, row < results.count else { return }
        let (url, matches) = results[row]
        let subrow = resultsTable.clickedRow >= 0 ? 0 : 0
        onOpenMatch?(url, matches[subrow].range)
    }
}

extension FindInFilesWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let (url, matches) = results[row]
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.font = NSFont.systemFont(ofSize: 11)
        let first = matches.first.map { (url.path, $0.range.location) } ?? (url.path, 0)
        label.stringValue = "\(first.0)\n\(matches.count) match(es), first at offset \(first.1)"
        label.maximumNumberOfLines = 2
        return label
    }
}
