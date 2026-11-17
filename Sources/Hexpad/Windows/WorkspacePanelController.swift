import AppKit
import HexpadKit

/// Minimal Open Folder as Workspace panel (v1).
///
/// Shows every text-ish file under the chosen folder as a flat, recursively
/// built table. Tree expansion, file watching and panel persistence are
/// deferred; the command and this listing are the v1 deliverable. Double-
/// clicking a row hands the absolute path to the owner, which opens it through
/// the normal tab-open path.
final class WorkspacePanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    /// Folder currently being listed. `update(rootURL:)` swaps it on the
    /// reused panel.
    private(set) var rootURL: URL

    /// Files under `rootURL`, sorted by relative path. Exposed for tests.
    private(set) var files: [URL] = []

    /// Called with the absolute path of the double-clicked file.
    var onOpenFile: ((String) -> Void)?

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")

    /// Extensions `Language.fromFileName` does not map but that are plainly
    /// text. The recognized mappings (the same table `ContentSniffer` consults)
    /// cover source files; this list adds everyday plain-text files.
    private static let plainTextExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "rst", "adoc", "asciidoc",
        "tex", "diff", "patch", "properties", "env", "editorconfig"
    ]

    init(rootURL: URL) {
        self.rootURL = rootURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workspace"
        window.minSize = NSSize(width: 320, height: 200)
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        super.init(window: window)
        buildUI()
        reloadFiles()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// Points the reused panel at a new folder and rebuilds the listing.
    func update(rootURL: URL) {
        self.rootURL = rootURL
        reloadFiles()
    }

    /// Rebuilds the flat listing. Hidden files and package descendants are
    /// skipped; only regular text-ish files are kept.
    func reloadFiles() {
        window?.title = "Workspace — \(rootURL.lastPathComponent)"

        var found: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        if let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard let isRegular = try? url.resourceValues(forKeys: Set(keys)).isRegularFile,
                      isRegular == true,
                      Self.isTextFile(url) else { continue }
                found.append(url)
            }
        }

        files = found.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        tableView.reloadData()
        statusLabel.stringValue = files.isEmpty
            ? "No text files found"
            : "\(files.count) file\(files.count == 1 ? "" : "s")"
    }

    /// Text-ish filter: a recognized language extension (the table
    /// `ContentSniffer.resolveLanguage` uses) or a plain-text extension.
    /// Extensionless names such as README or Makefile are kept: hidden files
    /// are already excluded by the enumerator, and workspace folders commonly
    /// hold those.
    static func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return true }
        return Language.fromFileName(url.lastPathComponent) != .plain
            || plainTextExtensions.contains(ext)
    }

    private func relativePath(for url: URL) -> String {
        let root = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.path.hasPrefix(root) else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.count))
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 34,
                                                width: content.bounds.width - 24,
                                                height: content.bounds.height - 46))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "Files"
        column.width = 460
        tableView.addTableColumn(column)
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        scroll.documentView = tableView
        content.addSubview(scroll)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 12, y: 11,
                                   width: content.bounds.width - 24, height: 16)
        statusLabel.autoresizingMask = [.width]
        content.addSubview(statusLabel)
    }

    @objc private func openSelected() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < files.count else { return }
        onOpenFile?(files[row].path)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        files.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < files.count else { return nil }
        let url = files[row]
        let label = NSTextField(labelWithString: relativePath(for: url))
        label.lineBreakMode = .byTruncatingMiddle
        label.font = NSFont.systemFont(ofSize: 12)
        label.toolTip = url.path
        return label
    }
}
