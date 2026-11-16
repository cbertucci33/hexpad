import AppKit

/// One row of the document switcher: a document identity plus the group it
/// lives in and the display strings the overlay renders.
///
/// The overlay deliberately holds only the document id, not the DocumentModel:
/// selecting a row routes back through MainWindowController, which resolves the
/// id against the owning TabStore and reuses the normal tab-selection path.
struct DocSwitcherItem: Equatable {
    let documentID: UUID
    let name: String
    let directory: String
    let group: TabGroup
}

/// Notepad++-style document switcher overlay.
///
/// A borderless floating panel with a search field and a table of every tab in
/// both groups. The search field owns the keyboard: its delegate intercepts the
/// arrow keys, Return and Escape before they reach the field editor, so the
/// overlay is completely keyboard driven while the document stays untouched.
final class DocSwitcherWindowController: NSWindowController,
                                         NSSearchFieldDelegate,
                                         NSTableViewDataSource,
                                         NSTableViewDelegate {

    /// Row chosen with Return or a double-click. The switcher dismisses itself
    /// first so the callback can restore editor focus.
    var onChoose: ((DocSwitcherItem) -> Void)?
    /// Escape (or a modifier-less cancel). No tab selection changes.
    var onCancel: (() -> Void)?

    private(set) var allItems: [DocSwitcherItem] = []
    private(set) var visibleItems: [DocSwitcherItem] = []
    /// Index into `visibleItems`, kept in step with the table's selection.
    private(set) var selectedIndex = 0

    let searchField = NSSearchField()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let hintLabel = NSTextField(labelWithString: "↑↓ select   ↵ open   esc cancel")
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("DocSwitcherCell")
    private var selectedDocumentID: UUID?
    private var isDismissing = false

    convenience init() {
        let panel = DocSwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                                     styleMask: [.borderless],
                                     backing: .buffered,
                                     defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        self.init(window: panel)
        panel.onCancel = { [weak self] in self?.cancel() }
        buildUI()
    }

    // MARK: - Presentation

    /// Shows the overlay centered over `parent`, pre-selecting the focused
    /// group's current document when it is in the list.
    func show(over parent: NSWindow,
              items: [DocSwitcherItem],
              selectedDocumentID: UUID?) {
        allItems = items
        self.selectedDocumentID = selectedDocumentID
        searchField.stringValue = ""
        applyFilter("")

        if let id = selectedDocumentID,
           let index = visibleItems.firstIndex(where: { $0.documentID == id }) {
            selectRow(index)
        } else {
            selectRow(visibleItems.isEmpty ? -1 : 0)
        }

        guard let panel = window else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2,
                                     y: parent.frame.midY - size.height / 2))
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    /// Removes the overlay without invoking either completion. Safe to call
    /// twice.
    func dismiss() {
        guard !isDismissing, let panel = window else { return }
        isDismissing = true
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.orderOut(nil)
        isDismissing = false
    }

    func cancel() {
        dismiss()
        onCancel?()
    }

    private func commitSelection() {
        guard visibleItems.indices.contains(selectedIndex) else {
            cancel()
            return
        }
        let item = visibleItems[selectedIndex]
        dismiss()
        onChoose?(item)
    }

    // MARK: - Filtering and selection

    private func applyFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            visibleItems = allItems
        } else {
            visibleItems = allItems.filter {
                $0.name.range(of: trimmed, options: .caseInsensitive) != nil
            }
        }
        tableView.reloadData()
    }

    private func selectRow(_ index: Int) {
        guard visibleItems.indices.contains(index) else {
            selectedIndex = 0
            tableView.deselectAll(nil)
            return
        }
        selectedIndex = index
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func moveSelection(by delta: Int) {
        guard !visibleItems.isEmpty else { return }
        let next = min(max(0, selectedIndex + delta), visibleItems.count - 1)
        selectRow(next)
    }

    // MARK: - UI

    private func buildUI() {
        guard let panel = window else { return }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 380))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        panel.contentView = root

        searchField.placeholderString = "Switch to document…"
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.frame = NSRect(x: 12, y: 340, width: 456, height: 28)
        searchField.autoresizingMask = [.width, .minYMargin]
        root.addSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))
        column.width = 460
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)

        scrollView.frame = NSRect(x: 8, y: 30, width: 464, height: 302)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView
        root.addSubview(scrollView)

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: 12, y: 8, width: 456, height: 16)
        hintLabel.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(hintLabel)
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, visibleItems.indices.contains(row) else { return }
        selectRow(row)
        commitSelection()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleItems.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard visibleItems.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? DocSwitcherCellView) ?? {
                let view = DocSwitcherCellView()
                view.identifier = Self.cellIdentifier
                return view
            }()
        cell.frame = NSRect(x: 0, y: 0, width: max(1, tableView.bounds.width), height: 40)
        cell.configure(with: visibleItems[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DocSwitcherRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 { selectedIndex = row }
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
        selectRow(visibleItems.isEmpty ? -1 : 0)
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}

/// A borderless panel must opt in to key status; without this the search field
/// could never take first responder and typing would go to the editor.
private final class DocSwitcherPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Row rendering: name, truncated directory, and group, with a subdued custom
/// selection background so the labels keep their normal colours on top.
private final class DocSwitcherCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let groupLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.usesSingleLineMode = true
        nameLabel.cell?.truncatesLastVisibleLine = true

        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.usesSingleLineMode = true
        pathLabel.cell?.truncatesLastVisibleLine = true

        groupLabel.font = NSFont.systemFont(ofSize: 10)
        groupLabel.textColor = .tertiaryLabelColor
        groupLabel.alignment = .right

        addSubview(nameLabel)
        addSubview(pathLabel)
        addSubview(groupLabel)
    }

    func configure(with item: DocSwitcherItem) {
        nameLabel.stringValue = item.name
        pathLabel.stringValue = item.directory
        groupLabel.stringValue = item.group == .primary ? "Group 1" : "Group 2"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let trailing: CGFloat = 86
        nameLabel.frame = NSRect(x: 10, y: height - 22, width: max(10, bounds.width - trailing), height: 17)
        pathLabel.frame = NSRect(x: 10, y: 5, width: max(10, bounds.width - trailing), height: 15)
        groupLabel.frame = NSRect(x: max(0, bounds.width - 78), y: height - 21, width: 68, height: 15)
    }
}

private final class DocSwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 1)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
}
