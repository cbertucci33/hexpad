import AppKit
import HexpadKit

/// One document's Find All results: the identity needed to jump back to the
/// right editor, and the matches found in that buffer.
///
/// The document itself is held weakly. Results outlive the tabs they came from,
/// and a strong reference here kept every closed buffer (plus its text storage)
/// alive for as long as the results window existed. The identity captured at
/// search time lets a closed document's group keep rendering as disabled rather
/// than disappearing or jumping nowhere.
struct DocumentSearchGroup {
    let documentID: DocumentModel.ID
    let name: String
    let filePath: URL?
    let matches: [DocumentMatch]

    /// Weak storage behind `document`. A closed buffer deallocates and leaves
    /// this nil; nothing in the results window keeps it alive.
    private weak var liveDocument: DocumentModel?

    init(document: DocumentModel, matches: [DocumentMatch]) {
        self.documentID = document.id
        self.name = document.name
        self.filePath = document.filePath
        self.liveDocument = document
        self.matches = matches
    }

    /// Live document, if its tab is still open. Optional so a closed buffer is
    /// an explicit absence at every call site; callers guard-let it (or check
    /// ``isDocumentOpen`` first) instead of risking an IUO trap.
    var document: DocumentModel? { liveDocument }

    /// Whether the tab behind this group is still open. A nil weak reference
    /// means the buffer was closed while the results were on screen.
    var isDocumentOpen: Bool { liveDocument != nil }

    /// Header title. File-backed documents show their path so two same-named
    /// files stay distinguishable; untitled buffers say so explicitly. Built
    /// from the captured metadata so a closed document still has a title.
    var title: String {
        filePath?.path ?? "\(name) (untitled)"
    }
}

/// One Find All run. Results accumulate as batches instead of erasing the
/// previous search, so a later query can be folded away without losing the
/// earlier hits. Re-running the *same* query refreshes its batch in place (the
/// pre-upgrade replace behaviour existing callers/tests rely on).
struct DocumentSearchBatch {
    let description: String
    let groups: [DocumentSearchGroup]
}

/// The table owns the two keyboard gestures the results window adds on top of
/// AppKit's selection machinery: Delete prunes the selected hit, Return jumps
/// to it. N++ uses F7 to *focus* its results window; that key is Windows/F-key
/// specific and would collide with AppKit/KeybindingStore chords here, so the
/// Mac equivalent is Enter/double-click on the row (see `openSelectedRow`).
private final class ResultsTableView: NSTableView {
    var onDeleteKey: (() -> Void)?
    var onEnterKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 51, 118: // Delete / Forward Delete (fn+Delete)
            onDeleteKey?()
        case 36, 76: // Return / keypad Enter
            onEnterKey?()
        default:
            super.keyDown(with: event)
        }
    }
}

/// Find in Files panel. SearchEngine.searchInFiles shipped complete but had no
/// UI at all. Runs the search off the main thread and opens a hit in a tab.
///
/// Also hosts the open-document Find All results (Search > Find All in Current
/// Document / in All Opened Documents). Both modes share the table; file
/// results keep their one-row-per-file summary, document results add per-file
/// group headers with one row per match so every hit is individually
/// double-clickable. Clicking a group header folds/unfolds it; folded matches
/// leave both the table and the F4 / Shift+F4 navigation order.
///
/// Wave 4A upgrades: different queries accumulate as foldable search batches,
/// Delete prunes the selected hit, a small context menu copies the path/line or
/// removes a hit, and Enter joins double-click as the jump-to-match gesture.
final class FindInFilesWindowController: NSWindowController {

    private let chooseButton = NSButton(title: "Choose Folder...", target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: "No folder chosen")
    /// N++-style file-type filter (`*.swift;*.md`) and directory exclusion
    /// filter (`node_modules;.build`). Both are parsed by
    /// `SearchEngine.parseFilterGlobs` and applied during file discovery.
    private let filtersField = NSTextField()
    private let excludeField = NSTextField()
    private let patternField = NSSearchField()
    private let replaceField = NSSearchField()
    private let regexCheckbox = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let caseCheckbox = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "Replace All in Files", target: nil, action: nil)
    private let resultsTable = ResultsTableView()
    private let resultsScrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")

    private enum Mode {
        case files
        case documents
    }
    private var mode: Mode = .files

    /// Row model for the document mode. A batch header (present once two or
    /// more searches are accumulated) wraps the per-file headers; each file
    /// header is followed by one row per match. Clicking a header folds it.
    private enum DocumentRow {
        case batchHeader(batch: Int)
        case header(group: Int)
        case match(group: Int, index: Int)
    }

    private var directory: URL?
    private var results: [(URL, [SearchMatch])] = []
    /// Replacements performed per file by the last Replace All in Files run.
    /// Kept alongside the search hits so the table can show both counts.
    private var replaceCounts: [URL: Int] = [:]

    /// Accumulated Find All runs, oldest first. `documentGroups` is the flat
    /// view of every batch so existing callers keep seeing one group per file.
    /// The list keeps only the most recent ``maximumBatchCount`` queries, so a
    /// long session of distinct searches cannot grow without bound.
    private(set) var searchBatches: [DocumentSearchBatch] = []
    private static let maximumBatchCount = 10
    private struct BatchLayout {
        let description: String
        let groupRange: Range<Int>
    }
    private var batchLayouts: [BatchLayout] = []
    private var lastSearchDescription = ""

    var documentGroups: [DocumentSearchGroup] { searchBatches.flatMap { $0.groups } }

    /// Visible document rows in display order. A folded group contributes its
    /// header but none of its match rows, so every consumer (table, F4
    /// navigation, openRow) reads the same list without a visibility filter.
    private var documentRows: [DocumentRow] = []
    /// Group indices the user collapsed by clicking their header.
    private var foldedGroups: Set<Int> = []
    /// Batch indices the user collapsed by clicking a search header.
    private var foldedBatches: Set<Int> = []

    /// Table row indices in navigation order: every file row in files mode,
    /// every match row (headers excluded) in documents mode. F4 / Shift+F4
    /// walk this flat list, so "next result" crosses file-group boundaries.
    private var resultRows: [Int] = []
    /// Index into `resultRows`, or -1 before the first jump / after a rebuild.
    private(set) var currentResultIndex = -1

    /// Called with the file URL and the match range to jump to in that file.
    var onOpenMatch: ((URL, NSRange) -> Void)?
    /// Called with the owning document and the exact match range for document
    /// results. The controller resolves the tab/group before scrolling.
    var onOpenDocumentMatch: ((DocumentModel, NSRange) -> Void)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 452),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Find in Files"
        window.minSize = NSSize(width: 420, height: 300)
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true

        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        chooseButton.bezelStyle = .rounded
        chooseButton.frame = NSRect(x: 12, y: 418, width: 130, height: 24)
        content.addSubview(chooseButton)

        folderLabel.font = NSFont.systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.frame = NSRect(x: 150, y: 422, width: 458, height: 16)
        folderLabel.autoresizingMask = [.width]
        content.addSubview(folderLabel)

        filtersField.placeholderString = "Filters: *.swift;*.md"
        filtersField.toolTip = "File types to search, separated by semicolons"
        filtersField.frame = NSRect(x: 12, y: 386, width: 288, height: 24)
        filtersField.autoresizingMask = [.width]
        content.addSubview(filtersField)

        excludeField.placeholderString = "Exclude: node_modules;.build"
        excludeField.toolTip = "Folders to skip, separated by semicolons"
        excludeField.frame = NSRect(x: 312, y: 386, width: 296, height: 24)
        excludeField.autoresizingMask = [.minXMargin, .width]
        content.addSubview(excludeField)

        patternField.placeholderString = "Search pattern"
        patternField.frame = NSRect(x: 12, y: 354, width: 380, height: 24)
        patternField.target = self
        patternField.action = #selector(runSearch)
        patternField.autoresizingMask = [.width]
        content.addSubview(patternField)

        regexCheckbox.frame = NSRect(x: 400, y: 356, width: 70, height: 20)
        content.addSubview(regexCheckbox)
        caseCheckbox.frame = NSRect(x: 474, y: 356, width: 110, height: 20)
        caseCheckbox.autoresizingMask = [.minXMargin]
        content.addSubview(caseCheckbox)

        searchButton.target = self
        searchButton.action = #selector(runSearch)
        searchButton.keyEquivalent = "\r"
        searchButton.frame = NSRect(x: 590, y: 354, width: 20, height: 24)
        searchButton.autoresizingMask = [.minXMargin]
        content.addSubview(searchButton)

        replaceField.placeholderString = "Replace with"
        replaceField.frame = NSRect(x: 12, y: 322, width: 380, height: 24)
        replaceField.autoresizingMask = [.width]
        content.addSubview(replaceField)

        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllInFiles)
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.font = NSFont.systemFont(ofSize: 12)
        replaceAllButton.frame = NSRect(x: 400, y: 320, width: 170, height: 24)
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
        resultsTable.action = #selector(handleResultsRowClick)
        resultsTable.doubleAction = #selector(openSelected)
        // Keyboard additions (Delete prunes, Enter jumps). Header rows are not
        // selectable, so both gestures only ever act on a real hit row.
        resultsTable.onDeleteKey = { [weak self] in self?.deleteSelectedResult() }
        resultsTable.onEnterKey = { [weak self] in self?.openSelectedRow() }
        resultsTable.menu = makeContextMenu()
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
        [chooseButton, folderLabel, filtersField, excludeField, patternField, replaceField,
         regexCheckbox, caseCheckbox, searchButton, replaceAllButton]
    }

    private func setFileInputsVisible(_ visible: Bool) {
        for control in fileInputControls {
            control.isHidden = !visible
        }
        guard let content = window?.contentView else { return }
        let bottomInset: CGFloat = 34
        // File mode leaves the four-row control band above the table;
        // document mode only needs the close/scroll/status band.
        let topInset: CGFloat = visible ? 146 : 10
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
        rebuildResultRows()
        resultsTable.reloadData()
    }

    /// Shows Find All results for open documents. `searchDescription` is the
    /// query echoed in the status line; the controller stays dumb about how the
    /// search was produced. A different query appends a new foldable batch;
    /// the same query refreshes the existing batch in place.
    func showDocumentResults(groups: [DocumentSearchGroup], searchDescription: String) {
        mode = .documents
        window?.title = "Search Results"
        setFileInputsVisible(false)

        // Preserve fold state across the refresh. Capture identity keys before
        // mutating the batch list so groups that survive (same document + same
        // matches signature) keep their collapsed state; groups that vanished are
        // dropped automatically.
        let oldGroups = documentGroups
        let oldFoldedKeys = Set(foldedGroups.compactMap { index -> String? in
            guard oldGroups.indices.contains(index) else { return nil }
            return groupKey(oldGroups[index])
        })
        let oldFoldedBatches = foldedBatches

        let batch = DocumentSearchBatch(description: searchDescription, groups: groups)
        // Refresh in place when this query already exists anywhere in the
        // accumulated list (not just as the last batch), so an A->B->A sequence
        // reuses the existing batch instead of appending a duplicate.
        var removedBatchCount = 0
        if let existingIndex = searchBatches.firstIndex(where: { $0.description == searchDescription }) {
            searchBatches[existingIndex] = batch
        } else {
            searchBatches.append(batch)
            // Keep the list bounded by dropping the oldest queries. Batch fold
            // indices shift left by the number removed (remapped below).
            let overflow = searchBatches.count - Self.maximumBatchCount
            if overflow > 0 {
                searchBatches.removeFirst(overflow)
                removedBatchCount = overflow
            }
        }
        lastSearchDescription = searchDescription
        rebuildBatchLayouts()

        // Preserve group fold state for groups that still exist (keyed by
        // document id + matches signature); clear it for groups that vanished.
        let newGroups = documentGroups
        var newFoldedGroups: Set<Int> = []
        for (index, group) in newGroups.enumerated() {
            if oldFoldedKeys.contains(groupKey(group)) {
                newFoldedGroups.insert(index)
            }
        }
        foldedGroups = newFoldedGroups
        // Keep batch folds that still point at a valid batch. Indices shift when
        // appending a new batch pushed the oldest ones past the cap.
        var newFoldedBatches: Set<Int> = []
        for index in oldFoldedBatches {
            let shifted = index - removedBatchCount
            if searchBatches.indices.contains(shifted) {
                newFoldedBatches.insert(shifted)
            }
        }
        foldedBatches = newFoldedBatches

        rebuildDocumentRows()
        updateSummaryStatus()
    }

    private func rebuildBatchLayouts() {
        var layouts: [BatchLayout] = []
        var nextGroup = 0
        for batch in searchBatches {
            let range = nextGroup..<(nextGroup + batch.groups.count)
            layouts.append(BatchLayout(description: batch.description, groupRange: range))
            nextGroup = range.upperBound
        }
        batchLayouts = layouts
    }

    private func updateSummaryStatus() {
        // Reflect the current navigation state when the cursor is on a result,
        // rather than a stale aggregate. Otherwise report an aggregate that is
        // not misleadingly attributed to a single (last) query, and exclude
        // empty groups (0 matches left) from the file count.
        if currentResultIndex >= 0,
           resultRows.indices.contains(currentResultIndex) {
            statusLabel.stringValue = "Result \(currentResultIndex + 1) of \(resultRows.count)"
            return
        }
        let matchCount = documentResultCount
        let fileCount = documentGroups.filter { !$0.matches.isEmpty }.count
        if matchCount == 0 {
            statusLabel.stringValue = "No matches"
        } else {
            statusLabel.stringValue = "\(matchCount) matches in \(fileCount) files"
        }
    }

    /// Total hits currently listed in document mode. Used by app tests.
    var documentResultCount: Int {
        documentGroups.reduce(0) { $0 + $1.matches.count }
    }

    /// Identity key for a result group, used to preserve fold state across a
    /// refresh. Document id plus a cheap matches signature: count and the first
    /// and last range. The previous key concatenated every match's text, which
    /// rebuilt an O(matches × text) string per group on every refresh; range
    /// endpoints are enough to distinguish a changed result set without it.
    private func groupKey(_ group: DocumentSearchGroup) -> String {
        let first = group.matches.first?.range
        let last = group.matches.last?.range
        let signature = "\(group.matches.count)"
            + "|\(first?.location ?? -1):\(first?.length ?? 0)"
            + "|\(last?.location ?? -1):\(last?.length ?? 0)"
        return "\(group.documentID)|\(signature)"
    }

    /// Number of rows F4 / Shift+F4 can visit. Used by app tests.
    var navigableResultCount: Int {
        guard mode == .documents else { return resultRows.count }
        return liveResultRows().count
    }

    /// Currently highlighted table row, or -1. Used by app tests.
    var selectedResultsRow: Int { resultsTable.selectedRow }

    /// Status line text. Used by app tests.
    var statusText: String { statusLabel.stringValue }

    /// Include globs parsed from the file-type filter field. Used by app tests.
    var includeGlobs: [String] { SearchEngine.parseFilterGlobs(filtersField.stringValue) }
    /// Exclude globs parsed from the directory-exclusion field. Used by app tests.
    var excludeGlobs: [String] { SearchEngine.parseFilterGlobs(excludeField.stringValue) }

    /// Test seam: installs the two filter fields without touching AppKit.
    func setFiltersForTesting(include: String, exclude: String) {
        filtersField.stringValue = include
        excludeField.stringValue = exclude
    }

    // MARK: - Group folding

    /// Builds the visible row list from `searchBatches` and the fold sets.
    /// Rebuilding (rather than filtering at read time) keeps navigation, the
    /// table view and openRow on one shared row model.
    private func rebuildDocumentRows() {
        documentRows = []
        let showsBatchHeaders = searchBatches.count > 1
        for (batchIndex, batch) in searchBatches.enumerated() {
            if showsBatchHeaders {
                documentRows.append(.batchHeader(batch: batchIndex))
            }
            guard !foldedBatches.contains(batchIndex) else { continue }
            guard batchLayouts.indices.contains(batchIndex) else { continue }
            for groupIndex in batchLayouts[batchIndex].groupRange {
                documentRows.append(.header(group: groupIndex))
                guard !foldedGroups.contains(groupIndex) else { continue }
                for matchIndex in documentGroups[groupIndex].matches.indices {
                    documentRows.append(.match(group: groupIndex, index: matchIndex))
                }
            }
        }
        rebuildResultRows()
        resultsTable.reloadData()
    }

    /// Collapses/expands one document group. Files mode has no groups, so the
    /// call is a no-op there.
    func toggleGroupFold(at groupIndex: Int) {
        guard mode == .documents,
              documentGroups.indices.contains(groupIndex) else { return }
        if foldedGroups.contains(groupIndex) {
            foldedGroups.remove(groupIndex)
        } else {
            foldedGroups.insert(groupIndex)
        }
        rebuildDocumentRows()
    }

    /// Whether the group's match rows are currently hidden. Used by app tests.
    func isGroupFolded(_ groupIndex: Int) -> Bool {
        foldedGroups.contains(groupIndex)
    }

    /// Collapses/expands one accumulated search batch. Folding a batch hides
    /// its file headers and all of its hits from the table and F4 navigation.
    func toggleBatchFold(at batchIndex: Int) {
        guard mode == .documents, searchBatches.indices.contains(batchIndex) else { return }
        if foldedBatches.contains(batchIndex) {
            foldedBatches.remove(batchIndex)
        } else {
            foldedBatches.insert(batchIndex)
        }
        rebuildDocumentRows()
    }

    func isBatchFolded(_ batchIndex: Int) -> Bool { foldedBatches.contains(batchIndex) }

    /// Header text for one group. Folded groups report "N matches"; expanded
    /// groups keep the pre-existing "N match(es)" summary. Used by the table
    /// and by app tests.
    func headerText(for groupIndex: Int) -> String? {
        guard documentGroups.indices.contains(groupIndex) else { return nil }
        let group = documentGroups[groupIndex]
        let marker = foldedGroups.contains(groupIndex) ? "▸" : "▾"
        if !group.isDocumentOpen {
            return "\(marker) \(group.title)  —  \(group.matches.count) matches (document closed)"
        }
        if foldedGroups.contains(groupIndex) {
            return "▸ \(group.title)  —  \(group.matches.count) matches"
        }
        return "▾ \(group.title)  —  \(group.matches.count) match(es)"
    }

    /// Header text for an accumulated search batch, including its hit count.
    func batchHeaderText(for batchIndex: Int) -> String? {
        guard searchBatches.indices.contains(batchIndex),
              batchLayouts.indices.contains(batchIndex) else { return nil }
        let description = searchBatches[batchIndex].description
        let range = batchLayouts[batchIndex].groupRange
        let count = documentGroups[range].reduce(0) { $0 + $1.matches.count }
        let fileCount = documentGroups[range].filter { !$0.matches.isEmpty }.count
        let marker = foldedBatches.contains(batchIndex) ? "▸" : "▾"
        return "\(marker) Search \(description)  —  \(count) matches in \(fileCount) files"
    }

    /// Single-click handler. Only headers act; a match row's click is left to
    /// the normal selection machinery. The second click of a double-click
    /// arrives as `openSelected` (doubleAction), not here.
    @objc private func handleResultsRowClick() {
        guard mode == .documents else { return }
        let row = resultsTable.clickedRow
        guard documentRows.indices.contains(row) else { return }
        switch documentRows[row] {
        case .header(let groupIndex):
            toggleGroupFold(at: groupIndex)
        case .batchHeader(let batchIndex):
            toggleBatchFold(at: batchIndex)
        case .match:
            break
        }
    }

    // MARK: - Delete pruning and context menu

    /// Removes the selected hit (Delete key or the context menu's Remove Hit).
    /// Header rows are not selectable, so the common case is always a hit.
    func deleteSelectedResult() {
        let row = resultsTable.selectedRow
        guard row >= 0 else { return }
        switch mode {
        case .files:
            guard results.indices.contains(row) else { return }
            results.remove(at: row)
            rebuildResultRows()
            resultsTable.reloadData()
        case .documents:
            guard documentRows.indices.contains(row),
                  case .match(let groupIndex, let matchIndex) = documentRows[row] else { return }
            removeHit(group: groupIndex, match: matchIndex)
        }
    }

    /// Removes one match from its group, keeping an (empty) file header so
    /// group indices — and therefore fold state and navigation — stay stable.
    func removeHit(group groupIndex: Int, match matchIndex: Int) {
        guard documentGroups.indices.contains(groupIndex) else { return }
        guard documentGroups[groupIndex].matches.indices.contains(matchIndex) else { return }
        guard let batchIndex = batchLayouts.firstIndex(where: {
            $0.groupRange.contains(groupIndex)
        }) else { return }
        let localIndex = groupIndex - batchLayouts[batchIndex].groupRange.lowerBound
        var groups = searchBatches[batchIndex].groups
        guard groups.indices.contains(localIndex) else { return }
        let old = groups[localIndex]
        // A closed document has no live model to build the trimmed group from;
        // its rows are already non-selectable, so leave the group untouched.
        guard let document = old.document else { return }
        let trimmed = DocumentSearchGroup(
            document: document,
            matches: old.matches.enumerated()
                .filter { $0.offset != matchIndex }
                .map { $0.element })
        groups[localIndex] = trimmed
        searchBatches[batchIndex] = DocumentSearchBatch(
            description: searchBatches[batchIndex].description, groups: groups)
        rebuildDocumentRows()
        updateSummaryStatus()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Search Result")
        menu.addItem(NSMenuItem(title: "Copy Path",
                                action: #selector(copySelectedPath(_:)),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Line",
                                action: #selector(copySelectedLine(_:)),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Remove Hit",
                                action: #selector(removeSelectedHit(_:)),
                                keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    /// Titles of the result-row context menu items. Used by app tests.
    var contextMenuTitles: [String] { resultsTable.menu?.items.map(\.title) ?? [] }

    /// Path the Copy Path menu item would place on the pasteboard for `row`.
    func copyablePath(forRow row: Int) -> String? {
        switch mode {
        case .files:
            guard results.indices.contains(row) else { return nil }
            return results[row].0.path
        case .documents:
            guard documentRows.indices.contains(row),
                  case .match(let groupIndex, _) = documentRows[row] else { return nil }
            return documentGroups[groupIndex].filePath?.path
        }
    }

    /// Line the Copy Line menu item would place on the pasteboard for `row`.
    func copyableLine(forRow row: Int) -> String? {
        switch mode {
        case .files:
            guard results.indices.contains(row) else { return nil }
            let (_, matches) = results[row]
            return matches.first?.text ?? ""
        case .documents:
            guard documentRows.indices.contains(row),
                  case .match(let groupIndex, let matchIndex) = documentRows[row] else { return nil }
            let match = documentGroups[groupIndex].matches[matchIndex]
            return "\(match.line): \(match.context)"
        }
    }

    @objc func copySelectedPath(_ sender: Any?) {
        let row = resultsTable.clickedRow >= 0 ? resultsTable.clickedRow : resultsTable.selectedRow
        guard let path = copyablePath(forRow: row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc func copySelectedLine(_ sender: Any?) {
        let row = resultsTable.clickedRow >= 0 ? resultsTable.clickedRow : resultsTable.selectedRow
        guard let line = copyableLine(forRow: row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    @objc func removeSelectedHit(_ sender: Any?) { deleteSelectedResult() }

    // MARK: - Result navigation

    /// Rebuilds the flat navigation order for the current mode and clears the
    /// cursor. Files mode lists each file once (its first hit is the target);
    /// documents mode lists each match row and skips all header rows.
    private func rebuildResultRows() {
        switch mode {
        case .files:
            resultRows = results.indices.filter { !results[$0].1.isEmpty }
        case .documents:
            resultRows = liveResultRows()
        }
        currentResultIndex = -1
        resultsTable.deselectAll(nil)
    }

    /// Table rows for matches whose documents are still open, in display order.
    /// Header rows and matches owned by closed documents are excluded, so the
    /// next F4 / Shift+F4 jump always lands on a live buffer.
    private func liveResultRows() -> [Int] {
        documentRows.indices.filter { row in
            guard case .match(let groupIndex, _) = documentRows[row] else { return false }
            return documentGroups[groupIndex].isDocumentOpen
        }
    }

    /// Drops match rows whose documents were closed since the row model was
    /// last rebuilt, so F4 / Shift+F4 never land on a dead hit. Dead groups stay
    /// in the table (headers and rows) but render disabled; keeping their
    /// indices stable means fold state and group indices do not shift when a
    /// tab closes. The cursor stays on the same match while it is still live.
    private func pruneClosedResultRows() {
        guard mode == .documents else { return }
        let previousRow = resultRows.indices.contains(currentResultIndex)
            ? resultRows[currentResultIndex] : nil
        let liveRows = liveResultRows()
        guard liveRows != resultRows else { return }
        resultRows = liveRows
        if let previousRow, let index = liveRows.firstIndex(of: previousRow) {
            currentResultIndex = index
        } else {
            currentResultIndex = -1
        }
        // Re-render so rows for the closed document show their disabled state.
        resultsTable.reloadData()
    }

    /// Search > Next Result (F4). Moves to the next row in navigation order,
    /// wrapping from the last result back to the first.
    func nextResult() {
        pruneClosedResultRows()
        guard !resultRows.isEmpty else {
            if documentsClosedMessageNeeded() {
                statusLabel.stringValue = "Matching documents are closed"
            }
            return
        }
        if currentResultIndex < 0 {
            currentResultIndex = 0
        } else {
            currentResultIndex = (currentResultIndex + 1) % resultRows.count
        }
        jumpToCurrentResult()
    }

    /// Search > Previous Result (Shift+F4). Wrapping mirrors `nextResult`;
    /// with no cursor yet it starts at the last result, N++ style.
    func previousResult() {
        pruneClosedResultRows()
        guard !resultRows.isEmpty else {
            if documentsClosedMessageNeeded() {
                statusLabel.stringValue = "Matching documents are closed"
            }
            return
        }
        if currentResultIndex < 0 {
            currentResultIndex = resultRows.count - 1
        } else {
            currentResultIndex = (currentResultIndex - 1 + resultRows.count) % resultRows.count
        }
        jumpToCurrentResult()
    }

    /// True when an empty navigation list is explained by closed documents
    /// rather than by a search with no hits.
    private func documentsClosedMessageNeeded() -> Bool {
        mode == .documents
            && documentGroups.contains { !$0.isDocumentOpen && !$0.matches.isEmpty }
    }

    /// Same action names as the main window's passthroughs. The results
    /// window is its own responder chain root, so its menu items stay live
    /// while it is key.
    @objc func nextSearchResult(_ sender: Any?) { nextResult() }
    @objc func previousSearchResult(_ sender: Any?) { previousResult() }

    private func jumpToCurrentResult() {
        guard resultRows.indices.contains(currentResultIndex) else { return }
        let row = resultRows[currentResultIndex]
        resultsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        resultsTable.scrollRowToVisible(row)
        updateSummaryStatus()
        openRow(row)
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
            let includeGlobs = self?.includeGlobs ?? []
            let excludeGlobs = self?.excludeGlobs ?? []
            let hits = SearchEngine.searchInFiles(directory: directory, pattern: pattern,
                                                  options: options,
                                                  includeGlobs: includeGlobs,
                                                  excludeGlobs: excludeGlobs)
            DispatchQueue.main.async {
                guard let self else { return }
                self.results = hits
                self.rebuildResultRows()
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
            let includeGlobs = self?.includeGlobs ?? []
            let excludeGlobs = self?.excludeGlobs ?? []
            let replaced = SearchEngine.replaceInFiles(directory: directory, pattern: pattern,
                                                       replacement: replacement, options: options,
                                                       includeGlobs: includeGlobs,
                                                       excludeGlobs: excludeGlobs)
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
                self.rebuildResultRows()
                self.resultsTable.reloadData()

                let total = replaced.reduce(0) { $0 + $1.1 }
                self.statusLabel.stringValue = replaced.isEmpty
                    ? "No matches to replace"
                    : "Replaced \(total) matches in \(replaced.count) files"
            }
        }
    }

    /// Double-click on a row. `clickedRow` is set for the mouse gesture; fall
    /// back to the selection for programmatic/test callers.
    @objc private func openSelected() {
        let row = resultsTable.clickedRow >= 0 ? resultsTable.clickedRow : resultsTable.selectedRow
        openRow(row)
    }

    /// Enter on the selected row: the Mac equivalent of N++'s results-window
    /// F7 focus + Enter jump. Kept separate from the double-click handler so
    /// tests and the key handler share one entry point.
    func openSelectedRow() {
        openRow(resultsTable.selectedRow)
    }

    /// Jumps to the result on `row`, using the mode's existing path. Shared by
    /// double-click, Enter and keyboard result navigation.
    private func openRow(_ row: Int) {
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
            // Double-click can still target a row whose document closed after
            // the table was built. Refresh the disabled styling and say why
            // instead of silently doing nothing.
            guard let document = group.document else {
                pruneClosedResultRows()
                statusLabel.stringValue = "\(group.title) is closed"
                return
            }
            onOpenDocumentMatch?(document, group.matches[matchIndex].range)
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
        switch documentRows[row] {
        case .header, .batchHeader: return false
        case .match(let groupIndex, _):
            return documentGroups[groupIndex].isDocumentOpen
        }
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
        case .batchHeader(let batchIndex):
            label.font = NSFont.boldSystemFont(ofSize: 11)
            label.stringValue = batchHeaderText(for: batchIndex) ?? ""
            label.maximumNumberOfLines = 1
        case .header(let groupIndex):
            let group = documentGroups[groupIndex]
            label.font = NSFont.boldSystemFont(ofSize: 11)
            label.stringValue = headerText(for: groupIndex) ?? ""
            label.toolTip = group.filePath?.path
            label.maximumNumberOfLines = 1
            if !group.isDocumentOpen {
                label.textColor = .disabledControlTextColor
            }
        case .match(let groupIndex, let matchIndex):
            let group = documentGroups[groupIndex]
            let match = group.matches[matchIndex]
            let preview = match.context.isEmpty ? "(blank line)" : match.context
            label.stringValue = "    \(match.line): \(preview)"
            label.toolTip = "Line \(match.line), column \(match.column): \(match.text)"
            label.maximumNumberOfLines = 1
            if !group.isDocumentOpen {
                label.stringValue = "    \(match.line): \(preview)  (document closed)"
                label.toolTip = "This document was closed; the hit can no longer be opened"
                label.textColor = .disabledControlTextColor
            }
        }
        return label
    }
}
