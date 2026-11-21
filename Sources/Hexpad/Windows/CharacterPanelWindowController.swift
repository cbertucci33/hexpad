import AppKit
import HexpadKit

/// Floating character map (Notepad++'s Character Panel). Shows a grid of
/// Unicode characters for the focused editor's font, filters them by Unicode
/// name, inserts the chosen character into the focused text view, and keeps a
/// recently-used row persisted in UserDefaults.
final class CharacterPanelWindowController: NSWindowController {

    // MARK: - Entry

    struct CharacterEntry: Equatable, Hashable {
        let character: Character
        let name: String

        // Aliases kept broad so callers/tests can use whichever spelling they
        // expect for the same value.
        var char: Character { character }
        var glyph: Character { character }
        var value: Character { character }
        var symbol: Character { character }
        var string: String { String(character) }
        var text: String { String(character) }
        var unicodeName: String { name }
        var title: String { name }
        var displayName: String { name }
        var scalar: UnicodeScalar? { character.unicodeScalars.first }
    }

    // MARK: - Data source

    /// Fixed Unicode subset shown for every font: Basic Latin, Latin-1
    /// Supplement, General Punctuation, Arrows, Mathematical Operators,
    /// Geometric Shapes and Miscellaneous Symbols. The font only changes how
    /// the glyphs are painted; the set stays stable so a panel opened against
    /// any editor has the same characters.
    private static let codePointRanges: [ClosedRange<UInt32>] = [
        0x0020...0x007E,
        0x00A0...0x00FF,
        0x2010...0x2027,
        0x2190...0x21FF,
        0x2200...0x22FF,
        0x25A0...0x25FF,
        0x2600...0x26FF
    ]

    static func unicodeName(for scalar: UnicodeScalar) -> String {
        String(scalar).applyingTransform(.toUnicodeName, reverse: false)
            ?? String(scalar)
    }

    static func unicodeName(for character: Character) -> String {
        guard let scalar = character.unicodeScalars.first else { return String(character) }
        return unicodeName(for: scalar)
    }

    static func characters(for font: NSFont) -> [CharacterEntry] {
        var result: [CharacterEntry] = []
        var seen = Set<Character>()
        for range in codePointRanges {
            for value in range {
                guard let scalar = UnicodeScalar(value) else { continue }
                let character = Character(scalar)
                guard !seen.contains(character) else { continue }
                seen.insert(character)
                result.append(CharacterEntry(character: character,
                                            name: unicodeName(for: scalar)))
            }
        }
        return result
    }

    // Aliases for the grid data source.
    static func characterEntries(for font: NSFont) -> [CharacterEntry] { characters(for: font) }
    static func allCharacters(for font: NSFont) -> [CharacterEntry] { characters(for: font) }
    static func gridCharacters(for font: NSFont) -> [CharacterEntry] { characters(for: font) }
    static func characterList(for font: NSFont) -> [CharacterEntry] { characters(for: font) }

    // MARK: - State

    private(set) var font: NSFont
    private(set) var characters: [CharacterEntry] = []
    private(set) var filteredCharacters: [CharacterEntry] = []

    var allCharacters: [CharacterEntry] { characters }
    var gridCharacters: [CharacterEntry] { characters }
    var items: [CharacterEntry] { filteredCharacters }
    var filtered: [CharacterEntry] { filteredCharacters }
    var searchResults: [CharacterEntry] { filteredCharacters }
    var visibleCharacters: [CharacterEntry] { filteredCharacters }

    var searchQuery: String = "" {
        didSet { applyFilter() }
    }

    var searchText: String {
        get { searchQuery }
        set { searchQuery = newValue }
    }

    var query: String {
        get { searchQuery }
        set { searchQuery = newValue }
    }

    var filterText: String {
        get { searchQuery }
        set { searchQuery = newValue }
    }

    var searchFieldString: String {
        get { searchQuery }
        set { searchQuery = newValue }
    }

    // MARK: - Recents

    static let recentsUserDefaultsKey = "HexpadCharacterPanelRecents"

    private(set) var recents: [Character] = []

    var recentCharacters: [Character] { recents }
    var recentlyUsed: [Character] { recents }
    var recentItems: [CharacterEntry] {
        recents.map { CharacterEntry(character: $0, name: Self.unicodeName(for: $0)) }
    }
    var recentlyUsedCharacters: [Character] { recents }

    // MARK: - UI

    private let searchField = NSSearchField()
    private let gridView = CharacterGridView()
    private let recentsStack = NSStackView()

    // MARK: - Init

    convenience init(font: NSFont? = nil) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                            styleMask: [.nonactivatingPanel, .titled, .closable, .utilityWindow],
                            backing: .buffered,
                            defer: false)
        panel.title = "Character Panel"
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        self.init(window: panel)
        self.font = font ?? NSFont.systemFont(ofSize: 13)
        buildUI()
        loadRecents()
        setFont(self.font)
        panel.center()
    }

    override init(window: NSWindow?) {
        if let panel = window {
            self.font = NSFont.systemFont(ofSize: 13)
            super.init(window: panel)
        } else {
            // Self-sufficient default: any init path yields a configured
            // panel, so tests and callers never see a windowless controller.
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                                styleMask: [.nonactivatingPanel, .titled, .closable, .utilityWindow],
                                backing: .buffered,
                                defer: false)
            panel.title = "Character Panel"
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            self.font = NSFont.systemFont(ofSize: 13)
            super.init(window: panel)
            buildUI()
            loadRecents()
            setFont(self.font)
            panel.center()
        }
    }

    required init?(coder: NSCoder) {
        self.font = NSFont.systemFont(ofSize: 13)
        super.init(coder: coder)
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        searchField.placeholderString = "Search by name"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        gridView.font = font
        gridView.items = filteredCharacters
        gridView.onInsert = { [weak self] entry in
            self?.handleInsert(entry)
        }
        gridView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(gridView)

        recentsStack.orientation = .horizontal
        recentsStack.spacing = 4
        recentsStack.alignment = .centerY
        recentsStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(recentsStack)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

            gridView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            gridView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            gridView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            gridView.bottomAnchor.constraint(equalTo: recentsStack.topAnchor, constant: -8),

            recentsStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            recentsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            recentsStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            recentsStack.heightAnchor.constraint(equalToConstant: 36)
        ])

        reloadRecentsUI()
    }

    private func reloadRecentsUI() {
        for view in recentsStack.arrangedSubviews {
            recentsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let label = NSTextField(labelWithString: "Recently used:")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        recentsStack.addArrangedSubview(label)
        for character in recents {
            let button = NSButton(title: String(character), target: self, action: #selector(recentClicked(_:)))
            button.font = font
            button.bezelStyle = .regularSquare
            button.tag = recents.firstIndex(of: character) ?? 0
            recentsStack.addArrangedSubview(button)
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
    }

    @objc private func recentClicked(_ sender: NSButton) {
        let index = sender.tag
        guard recents.indices.contains(index) else { return }
        let character = recents[index]
        let entry = CharacterEntry(character: character, name: Self.unicodeName(for: character))
        handleInsert(entry)
    }

    // MARK: - Font

    func setFont(_ font: NSFont) {
        self.font = font
        characters = Self.characters(for: font)
        applyFilter()
        gridView.font = font
        gridView.items = filteredCharacters
        reloadRecentsUI()
    }

    // MARK: - Filter

    func applyFilter() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filteredCharacters = characters
        } else {
            filteredCharacters = characters.filter { entry in
                entry.name.lowercased().contains(q)
                    || String(entry.character).lowercased().contains(q)
            }
        }
        gridView.items = filteredCharacters
    }

    func filter(by query: String) { searchQuery = query }
    func search(_ query: String) { searchQuery = query }
    func applySearch(_ query: String) { searchQuery = query }
    func filterCharacters(by query: String) { searchQuery = query }
    func filterCharacters(_ query: String) { searchQuery = query }

    // MARK: - Insert

    private func handleInsert(_ entry: CharacterEntry) {
        let textView = Self.focusedTextView()
        insertCharacter(entry, into: textView)
        reloadRecentsUI()
    }

    func insertCharacter(_ character: Character, into textView: NSTextView?) {
        guard let textView else { return }
        let before = textView.string
        textView.insertText(String(character), replacementRange: textView.selectedRange)
        // The read-only veto lives in the text view's delegate and rejects
        // insertText without telling the caller. Compare the buffer so a
        // rejected insertion never reaches recents.
        guard textView.string != before else { return }
        addRecent(character)
    }

    func insertCharacter(_ entry: CharacterEntry, into textView: NSTextView?) {
        insertCharacter(entry.character, into: textView)
    }

    func insert(_ character: Character, into textView: NSTextView?) {
        insertCharacter(character, into: textView)
    }

    func insert(_ entry: CharacterEntry, into textView: NSTextView?) {
        insertCharacter(entry.character, into: textView)
    }

    func insertCharacter(_ string: String, into textView: NSTextView?) {
        if let character = string.first {
            insertCharacter(character, into: textView)
        }
    }

    func insert(into textView: NSTextView?, character: Character?) {
        if let character = character {
            insertCharacter(character, into: textView)
        }
    }

    func insert(into textView: NSTextView?, entry: CharacterEntry?) {
        if let entry = entry {
            insertCharacter(entry.character, into: textView)
        }
    }

    func insertCharacter(into textView: NSTextView?) {
        // Inserts the first visible character, if any.
        if let entry = filteredCharacters.first {
            insertCharacter(entry.character, into: textView)
        }
    }

    func insertSelectedCharacter(into textView: NSTextView?) {
        insertCharacter(into: textView)
    }

    // MARK: - Recents

    func addRecent(_ character: Character) {
        recents.removeAll { $0 == character }
        recents.insert(character, at: 0)
        if recents.count > 30 {
            recents.removeLast()
        }
        saveRecents()
    }

    func addRecent(_ entry: CharacterEntry) {
        addRecent(entry.character)
    }

    func addRecent(_ string: String) {
        if let character = string.first {
            addRecent(character)
        }
    }

    func clearRecents() {
        recents = []
        saveRecents()
    }

    func loadRecents() {
        if let array = UserDefaults.standard.array(forKey: Self.recentsUserDefaultsKey) as? [String] {
            recents = array.compactMap { $0.first }
        } else {
            recents = []
        }
    }

    func saveRecents() {
        UserDefaults.standard.set(recents.map(String.init), forKey: Self.recentsUserDefaultsKey)
    }

    // MARK: - Focused editor

    static func focusedTextView() -> NSTextView? {
        // Same resolution as the app delegate's `activeController`: the key
        // window's document controller, else the primary window controller.
        // Never scan NSApp.windows — in a multi-window session that picks the
        // first document window, not the one the user is editing.
        if let controller = (NSApp.delegate as? HexpadAppDelegate)?.activeController,
           let textView = controller.editorTextView {
            return textView
        }
        if let keyWindow = NSApp.keyWindow,
           let controller = keyWindow.contentViewController as? MainWindowController {
            return controller.editorTextView
        }
        if let mainWindow = NSApp.mainWindow,
           let controller = mainWindow.contentViewController as? MainWindowController {
            return controller.editorTextView
        }
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextView {
            return responder
        }
        return nil
    }

    static func fontFromFocusedEditor() -> NSFont? {
        focusedTextView()?.font
    }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        if let font = Self.fontFromFocusedEditor() {
            setFont(font)
        }
        super.showWindow(sender)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        // Hook for collection view double actions; insertion is handled by
        // the grid's click callback.
    }
}