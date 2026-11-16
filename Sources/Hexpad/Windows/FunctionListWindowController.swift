import AppKit
import HexpadKit

/// Document outline panel for the selected tab.
///
/// The window is a normal, non-modal utility window rather than a sheet or an
/// editor takeover: the document stays interactive while the list is open.
/// It mirrors ``FindInFilesWindowController``'s conventions (separate window,
/// table-backed results, Close via Escape) and reuses one instance for the
/// lifetime of the main window.
///
/// The data comes straight from ``FunctionListModel`` built on the document's
/// current text and lexer definition. The model already sorts by document
/// position and owns all the line math, so this controller never re-sorts or
/// recomputes line numbers; it just renders what the model produced.
final class FunctionListWindowController: NSWindowController {

    /// Symbols currently shown, in the model's document order. Exposed for the
    /// app test bundle so the panel's population can be asserted directly.
    private(set) var symbols: [FunctionSymbol] = []

    /// Called with the chosen symbol. The main controller routes this into the
    /// editor's normal selection + scroll path.
    var onSelectSymbol: ((FunctionSymbol) -> Void)?

    private let tableView = FunctionListTableView()

    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let kindColumn = NSUserInterfaceItemIdentifier("kind")
    private static let lineColumn = NSUserInterfaceItemIdentifier("line")

    /// Identity of the last build. Repeating notifications for an unchanged
    /// buffer (for example a tab refresh immediately after a debounced update)
    /// are dropped before the model runs its regex pass again.
    private var lastDocumentID: UUID?
    private var lastText: String?
    private var lastLanguageName: String?
    private var hasDocument = false
    private var language: Language = .plain
    private var hasSymbolMetadata = false

    convenience init() {
        let window = FunctionListWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Function List"
        window.minSize = NSSize(width: 240, height: 180)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        self.init(window: window)
        buildUI()
    }

    // MARK: - Content

    /// Rebuilds the outline from `document`, or clears it when there is none.
    ///
    /// `FunctionListModel` is the only thing that scans the text; the app layer
    /// does not tokenize separately.
    func update(document: DocumentModel?) {
        guard let document else {
            hasDocument = false
            language = .plain
            hasSymbolMetadata = false
            lastDocumentID = nil
            lastText = nil
            lastLanguageName = nil
            symbols = []
            tableView.reloadData()
            return
        }

        let currentLanguage = Language(rawValue: document.language) ?? .plain
        if lastDocumentID == document.id,
           lastText == document.text,
           lastLanguageName == document.language {
            return
        }

        lastDocumentID = document.id
        lastText = document.text
        lastLanguageName = document.language
        hasDocument = true
        language = currentLanguage
        hasSymbolMetadata = !(LexerDefinitions.definition(for: currentLanguage)?.symbols?.isEmpty ?? true)

        symbols = FunctionListModel(text: document.text, language: currentLanguage).symbols
        tableView.reloadData()
    }

    /// Highlights a row and invokes the navigation callback. Double-click and
    /// Return both land here; an out-of-range row (such as the empty hint) is
    /// ignored.
    func activateRow(_ row: Int) {
        guard symbols.indices.contains(row) else { return }
        onSelectSymbol?(symbols[row])
    }

    /// Gives the table keyboard focus when the panel is ordered front, so
    /// Return navigates and Escape closes without an extra click.
    func focusTable() {
        window?.makeFirstResponder(tableView)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        focusTable()
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        let scroll = NSScrollView(frame: content.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let nameColumn = NSTableColumn(identifier: Self.nameColumn)
        nameColumn.title = "Name"
        nameColumn.width = 190
        nameColumn.minWidth = 110
        tableView.addTableColumn(nameColumn)

        let kindColumn = NSTableColumn(identifier: Self.kindColumn)
        kindColumn.title = "Kind"
        kindColumn.width = 80
        kindColumn.minWidth = 60
        tableView.addTableColumn(kindColumn)

        let lineColumn = NSTableColumn(identifier: Self.lineColumn)
        lineColumn.title = "Line"
        lineColumn.width = 50
        lineColumn.minWidth = 40
        tableView.addTableColumn(lineColumn)

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 18
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateClickedRow)
        tableView.onActivateRow = { [weak self] row in
            self?.activateRow(row)
        }
        tableView.onCancel = { [weak self] in
            self?.window?.close()
        }

        scroll.documentView = tableView
        content.addSubview(scroll)
    }

    @objc private func activateClickedRow() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        activateRow(row)
    }

    private var hintText: String {
        guard hasDocument else { return "No document open" }
        guard hasSymbolMetadata else {
            return "\(language.rawValue) has no function-list symbols"
        }
        return "No symbols found in this document"
    }

    private func makeCell(_ text: String,
                          alignment: NSTextAlignment = .left,
                          color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = alignment
        label.textColor = color
        return label
    }
}

// MARK: - Table content

extension FunctionListWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        // The empty state is still one row so the panel explains itself
        // instead of looking like a rendering failure.
        symbols.isEmpty ? 1 : symbols.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }

        guard symbols.indices.contains(row) else {
            guard identifier == Self.nameColumn else { return nil }
            return makeCell(hintText, color: .secondaryLabelColor)
        }

        let symbol = symbols[row]
        switch identifier {
        case Self.nameColumn:
            return makeCell(symbol.name)
        case Self.kindColumn:
            return makeCell(symbol.kind.rawValue.capitalized)
        case Self.lineColumn:
            // Exactly the model's 1-based logical line; no local recount.
            return makeCell("\(symbol.line)", alignment: .right)
        default:
            return nil
        }
    }
}

// MARK: - Window / table keyboard behaviour

/// Escape closes the panel from any focus position in the window.
private final class FunctionListWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Table subclass that turns Return into "open selected symbol" and Escape
/// into "close panel". `cancelOperation` alone is not enough while the table
/// has focus, because NSTableView consumes the Escape key event.
private final class FunctionListTableView: NSTableView {

    var onActivateRow: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onCancel?()
        case 36, 76: // Return, keypad Enter
            onActivateRow?(selectedRow)
        default:
            super.keyDown(with: event)
        }
    }
}
