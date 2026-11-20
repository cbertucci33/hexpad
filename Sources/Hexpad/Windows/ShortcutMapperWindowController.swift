import AppKit
import HexpadKit

/// One row in the Shortcut Mapper table.
struct ShortcutMapperEntry: Equatable {
    let title: String
    let chord: String
    /// Registry command identifier when the row came from (or matched) a
    /// registry command; nil for app-level menu items such as Save or Quit.
    let identifier: String?
}

/// Read-only model behind the Shortcut Mapper window.
///
/// Rows are collected by walking the live app menu first, so every chord is
/// the one actually installed right now — including user overrides applied to
/// the Text menu and the Keybindings submenu. Commands that no menu currently
/// carries fall back to `KeybindingStore`'s resolved defaults, which keeps the
/// list complete even for commands whose menu section has not been built yet.
enum ShortcutMapperModel {

    /// The table's full contents. Passing `nil` skips the menu walk and lists
    /// only registry commands with their resolved bindings.
    static func entries(menu: NSMenu? = nil) -> [ShortcutMapperEntry] {
        var rows: [ShortcutMapperEntry] = []
        var seenIdentifiers = Set<String>()

        if let menu {
            collectCommands(from: menu, into: &rows, seenIdentifiers: &seenIdentifiers)
        }

        for command in CommandRegistry.default.allMapperCommands {
            guard !seenIdentifiers.contains(command.identifier) else { continue }
            let binding = KeybindingStore.resolvedBinding(for: command.identifier)
            rows.append(ShortcutMapperEntry(title: command.title,
                                            chord: KeybindingStore.displayString(for: binding),
                                            identifier: command.identifier))
            seenIdentifiers.insert(command.identifier)
        }
        return rows
    }

    /// Depth-first walk of every actionable menu item, in menu order. Parents
    /// (action nil) are containers, not commands, but their submenus still
    /// count. An item with no key equivalent is listed with "None" so the
    /// mapper shows unbound commands rather than hiding them.
    private static func collectCommands(from menu: NSMenu,
                                        into rows: inout [ShortcutMapperEntry],
                                        seenIdentifiers: inout Set<String>) {
        for item in menu.items where !item.isSeparatorItem {
            if item.action != nil, !item.title.isEmpty {
                let identifier = item.representedObject as? String
                rows.append(ShortcutMapperEntry(
                    title: item.title,
                    chord: KeybindingStore.displayString(keyEquivalent: item.keyEquivalent,
                                                         modifierMask: item.keyEquivalentModifierMask),
                    identifier: identifier))
                if let identifier {
                    seenIdentifiers.insert(identifier)
                }
            }
            if let submenu = item.submenu {
                collectCommands(from: submenu, into: &rows, seenIdentifiers: &seenIdentifiers)
            }
        }
    }

    /// Case-insensitive contains match over the command title, chord and
    /// identifier. Whitespace-only queries return everything.
    static func filtered(_ entries: [ShortcutMapperEntry], query: String) -> [ShortcutMapperEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.chord.localizedCaseInsensitiveContains(needle)
                || ($0.identifier?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }
}

extension CommandRegistry {

    /// Every registered command group in stable order, deduped by identifier.
    ///
    /// ``allCommands`` intentionally omits the newer Search groups, which are
    /// not part of the legacy pinned list; the mapper wants the whole catalog.
    var allMapperCommands: [EditorCommand] {
        var seen = Set<String>()
        var result: [EditorCommand] = []
        for command in commands + bookmarkCommands + toolCommands + dateCommands
            + lineOpCommands + caseCommands + indentCommands + viewCommands
            + tokenStyleCommands + multiSelectCommands + beginEndSelectCommands
            + commentCommands + blankOpCommands + bookmarkLineOpCommands
        where seen.insert(command.identifier).inserted {
            result.append(command)
        }
        return result
    }
}

/// Notepad++'s Settings > Shortcut Mapper, v1 basics: a read-only, searchable
/// table of every menu command and its current key chord.
///
/// The window deliberately offers no editing controls; reassignment arrives in
/// a later update. The table is populated from the live main menu so the chords
/// shown are the ones actually installed, with `KeybindingStore` as the
/// fallback for commands no menu currently carries.
final class ShortcutMapperWindowController: NSWindowController {

    private(set) var allEntries: [ShortcutMapperEntry] = []
    private(set) var visibleEntries: [ShortcutMapperEntry] = []

    let searchField = NSSearchField()
    let tableView = NSTableView()
    let noteLabel = NSTextField(labelWithString: "Editing comes in a later update.")

    /// Designated init is self-sufficient: handed nil (or constructed via the
    /// inherited `init()`), it builds a configured window, so tests and
    /// callers never see a windowless controller.
    override init(window: NSWindow?) {
        if let window {
            super.init(window: window)
        } else {
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
            newWindow.title = "Shortcut Mapper"
            newWindow.isReleasedWhenClosed = false
            super.init(window: newWindow)
            buildUI()
            reloadData(from: nil)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    convenience init(menu: NSMenu? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Shortcut Mapper"
        // Reused for the app's lifetime, like Preferences.
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
        reloadData(from: menu)
    }

    /// Rebuilds the table from `menu` (normally `NSApp.mainMenu`) and re-applies
    /// the current search text.
    func reloadData(from menu: NSMenu?) {
        allEntries = ShortcutMapperModel.entries(menu: menu)
        applyFilter()
    }

    /// Re-filters `allEntries` with the search field's current text.
    func applyFilter() {
        visibleEntries = ShortcutMapperModel.filtered(allEntries, query: searchField.stringValue)
        tableView.reloadData()
    }

    /// The search text currently applied.
    var currentQuery: String { searchField.stringValue }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        searchField.placeholderString = "Search commands or shortcuts"
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.frame = NSRect(x: 20, y: 452, width: 600, height: 24)
        searchField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(searchField)

        let commandColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        commandColumn.title = "Command"
        commandColumn.width = 440
        let chordColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chord"))
        chordColumn.title = "Shortcut"
        chordColumn.width = 140
        tableView.addTableColumn(commandColumn)
        tableView.addTableColumn(chordColumn)
        tableView.headerView = NSTableHeaderView(frame: .zero)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 60, width: 600, height: 372))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]
        content.addSubview(scrollView)

        noteLabel.font = NSFont.systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.frame = NSRect(x: 20, y: 20, width: 600, height: 24)
        noteLabel.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(noteLabel)
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        applyFilter()
    }
}

extension ShortcutMapperWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }

    func tableView(_ tableView: NSTableView,
                   objectValueFor tableColumn: NSTableColumn?,
                   row: Int) -> Any? {
        guard row >= 0, row < visibleEntries.count else { return nil }
        let entry = visibleEntries[row]
        switch tableColumn?.identifier.rawValue {
        case "command": return entry.title
        case "chord": return entry.chord
        default: return nil
        }
    }

    /// v1 basics are strictly read-only.
    func tableView(_ tableView: NSTableView,
                   shouldEdit tableColumn: NSTableColumn?,
                   row: Int) -> Bool {
        false
    }
}
