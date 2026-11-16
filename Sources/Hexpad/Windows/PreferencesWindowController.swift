import AppKit
import HexpadKit

extension Notification.Name {
    /// Posted after preferences are saved or reset. The notification object is
    /// the normalized ``Preferences`` value that was written, so observers can
    /// apply it without reading the file again.
    static let preferencesDidChange = Notification.Name("HexpadPreferencesDidChange")
}

// MARK: - Model

/// User-facing editor preferences persisted in
/// `Application Support/Hexpad/preferences.json`.
///
/// Every key has a default, and decoding is per-key tolerant: a file that is
/// missing keys, stores the wrong type for one key, or names a theme that no
/// longer exists still yields a usable value for every other key. Out-of-range
/// numbers are clamped by ``normalized()``.
struct Preferences: Codable, Equatable {

    /// Bounds shared by the store and the Font pane controls.
    static let fontSizeRange: ClosedRange<CGFloat> = 8...72
    static let tabSizeRange: ClosedRange<Int> = 1...16

    var fontFamily: String
    var fontSize: CGFloat
    var wordWrap: Bool
    var autoIndent: Bool
    var autoCloseBrackets: Bool
    var tabSize: Int
    var useTabs: Bool
    /// A ``HexpadTheme`` raw value ("Light", "Dark", "Classic", "Monokai").
    var theme: String

    init(fontFamily: String = "Menlo",
         fontSize: CGFloat = 13,
         wordWrap: Bool = false,
         autoIndent: Bool = true,
         autoCloseBrackets: Bool = false,
         tabSize: Int = 4,
         useTabs: Bool = false,
         theme: String = HexpadTheme.light.rawValue) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.wordWrap = wordWrap
        self.autoIndent = autoIndent
        self.autoCloseBrackets = autoCloseBrackets
        self.tabSize = tabSize
        self.useTabs = useTabs
        self.theme = theme
    }

    /// The values a fresh install starts with. Tests compare against this, so
    /// it is the single source of truth for every key.
    static let defaults = Preferences()

    /// The selected theme, falling back to Light for an unknown raw value.
    var selectedTheme: HexpadTheme {
        HexpadTheme(rawValue: theme) ?? .light
    }

    /// Clamps ranges and replaces unrepresentable values, so the store never
    /// persists a size the controls cannot show.
    func normalized() -> Preferences {
        var result = self

        if result.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.fontFamily = Preferences.defaults.fontFamily
        }

        let size = result.fontSize.isFinite ? result.fontSize : Preferences.defaults.fontSize
        result.fontSize = min(max(size, Preferences.fontSizeRange.lowerBound),
                              Preferences.fontSizeRange.upperBound)
        result.tabSize = min(max(result.tabSize, Preferences.tabSizeRange.lowerBound),
                             Preferences.tabSizeRange.upperBound)

        if HexpadTheme(rawValue: result.theme) == nil {
            result.theme = Preferences.defaults.theme
        }

        return result
    }

    // Per-key decoding: a type mismatch on one key must not discard the rest.
    // The synthesized decoder would throw for the whole object instead.

    enum CodingKeys: String, CodingKey {
        case fontFamily, fontSize, wordWrap, autoIndent, autoCloseBrackets
        case tabSize, useTabs, theme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Preferences.defaults

        fontFamily = (try? container.decode(String.self, forKey: .fontFamily)) ?? fallback.fontFamily
        fontSize = (try? container.decode(CGFloat.self, forKey: .fontSize)) ?? fallback.fontSize
        wordWrap = (try? container.decode(Bool.self, forKey: .wordWrap)) ?? fallback.wordWrap
        autoIndent = (try? container.decode(Bool.self, forKey: .autoIndent)) ?? fallback.autoIndent
        autoCloseBrackets = (try? container.decode(Bool.self, forKey: .autoCloseBrackets))
            ?? fallback.autoCloseBrackets
        tabSize = (try? container.decode(Int.self, forKey: .tabSize)) ?? fallback.tabSize
        useTabs = (try? container.decode(Bool.self, forKey: .useTabs)) ?? fallback.useTabs
        theme = (try? container.decode(String.self, forKey: .theme)) ?? fallback.theme

        self = normalized()
    }
}

// MARK: - Store

/// Reads and writes ``Preferences`` next to the app's session and keybinding
/// files. A missing, unreadable, or malformed file always degrades to
/// ``Preferences/defaults`` rather than failing app startup.
enum PreferencesStore {

    /// Test seam: when set, preferences.json lives here instead of Application
    /// Support. Production never sets this; tests point it at a temp dir.
    static var overrideDirectory: URL?

    private static var appSupportDir: URL {
        if let override = overrideDirectory { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hexpad")
    }

    static var preferencesFileURL: URL {
        appSupportDir.appendingPathComponent("preferences.json")
    }

    // MARK: - Loading

    /// Current preferences, or the defaults when nothing usable is on disk.
    static func load() -> Preferences {
        guard let data = try? Data(contentsOf: preferencesFileURL) else {
            return .defaults
        }
        guard let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return .defaults
        }
        return decoded.normalized()
    }

    // MARK: - Saving

    /// Persists `preferences` (normalized) and posts `.preferencesDidChange`.
    @discardableResult
    static func save(_ preferences: Preferences) throws -> Preferences {
        let normalized = preferences.normalized()
        try FileManager.default.createDirectory(at: appSupportDir,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        try data.write(to: preferencesFileURL, options: .atomic)
        postChange(normalized)
        return normalized
    }

    /// Reads the current file, applies one mutation, writes it back. Panes use
    /// this so changing one control never clobbers a concurrent change to
    /// another key.
    @discardableResult
    static func update(_ mutate: (inout Preferences) -> Void) throws -> Preferences {
        var preferences = load()
        mutate(&preferences)
        return try save(preferences)
    }

    /// Deletes the preferences file, restoring every default. Posts
    /// `.preferencesDidChange` with the default value.
    static func resetToDefaults() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: preferencesFileURL.path) {
            try fileManager.removeItem(at: preferencesFileURL)
        }
        postChange(.defaults)
    }

    private static func postChange(_ preferences: Preferences) {
        NotificationCenter.default.post(name: .preferencesDidChange, object: preferences)
    }
}

// MARK: - Live application

/// Applies preferences to the editor that is currently on screen.
///
/// `MainWindowController` exposes its text view and its view hierarchy, but it
/// owns font/highlighting state privately. Applying through those read-only
/// accessors keeps this slice out of the window controller. Per-document
/// defaults (theme persistence across tab switches, auto-indent, auto-close,
/// tab size) still need controller support; see the follow-up note in
/// ``PreferencesWindowController``.
enum PreferencesApplier {

    /// Which editor aspects to touch. The Preferences panes apply only what
    /// they changed, so changing the font never repaints an unrelated theme.
    struct Options: OptionSet {
        let rawValue: Int
        static let font = Options(rawValue: 1 << 0)
        static let wrap = Options(rawValue: 1 << 1)
        static let theme = Options(rawValue: 1 << 2)
        static let all: Options = [.font, .wrap, .theme]
    }

    static func apply(_ preferences: Preferences,
                      to controller: MainWindowController?,
                      options: Options = .all) {
        guard let controller else { return }
        let editor = editorContainer(in: controller.view)
        let textView = editor?.textView ?? controller.editorTextView

        if options.contains(.font) {
            applyFont(preferences, editor: editor, textView: textView)
        }
        if options.contains(.wrap) {
            applyWordWrap(preferences.wordWrap, to: textView)
        }
        if options.contains(.theme) {
            applyTheme(preferences.selectedTheme, to: textView)
        }
    }

    // MARK: Font

    static func resolvedFont(family: String, size: CGFloat) -> NSFont {
        let clamped = min(max(size, Preferences.fontSizeRange.lowerBound),
                          Preferences.fontSizeRange.upperBound)
        return NSFontManager.shared.font(withFamily: family,
                                         traits: [],
                                         weight: 5,
                                         size: clamped)
            ?? NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
    }

    static func applyFont(_ preferences: Preferences,
                          editor: EditorContainer?,
                          textView: NSTextView?) {
        let font = resolvedFont(family: preferences.fontFamily, size: preferences.fontSize)
        if let editor {
            // Updates bodyFont as well, so the next tab bind keeps the choice.
            editor.setBodyFont(font)
        } else {
            textView?.font = font
        }
    }

    // MARK: Word wrap

    /// The editor maps word wrap to `isHorizontallyResizable` in reverse, which
    /// is exactly what the View > Word Wrap menu toggles.
    static func applyWordWrap(_ enabled: Bool, to textView: NSTextView?) {
        textView?.isHorizontallyResizable = !enabled
    }

    // MARK: Theme

    static func applyTheme(_ theme: HexpadTheme, to textView: NSTextView?) {
        guard let textView else { return }
        let palette = theme.theme
        let previous = detectedTheme(of: textView)

        // Snapshot the token runs before `textColor` flattens the storage to the
        // new foreground. The window controller's own palette is keyed off the
        // effective appearance, so this direct pass is what makes
        // Classic/Monokai token colors visible immediately.
        let replacements: [(range: NSRange, color: NSColor)]
        if let previous, previous != theme {
            replacements = tokenColorReplacements(from: previous.theme, to: palette, in: textView)
        } else {
            replacements = []
        }

        textView.backgroundColor = palette.background
        textView.textColor = palette.foreground
        textView.insertionPointColor = palette.foreground
        textView.enclosingScrollView?.drawsBackground = true
        textView.enclosingScrollView?.backgroundColor = palette.background

        if !replacements.isEmpty, let storage = textView.textStorage {
            storage.beginEditing()
            for replacement in replacements {
                storage.addAttribute(.foregroundColor,
                                     value: replacement.color,
                                     range: replacement.range)
            }
            storage.endEditing()
        }
    }

    /// The theme whose background is currently painted. Falls back to the
    /// appearance-derived Light/Dark palette, which is what the window
    /// controller uses before a preference has been applied.
    static func detectedTheme(of textView: NSTextView) -> HexpadTheme? {
        if let background = textView.backgroundColor.usingColorSpace(.sRGB) {
            for theme in HexpadTheme.allCases {
                guard let candidate = theme.theme.background.usingColorSpace(.sRGB) else { continue }
                if colorsMatch(candidate, background) { return theme }
            }
        }
        return HexpadTheme(rawValue: HexpadTheme.forAppearance(textView.effectiveAppearance).name)
    }

    private static func tokenColorReplacements(from old: Theme,
                                               to new: Theme,
                                               in textView: NSTextView) -> [(range: NSRange, color: NSColor)] {
        guard let storage = textView.textStorage, storage.length > 0 else { return [] }

        // Old palette color -> new palette color, for every token the themes
        // share. Ambiguous duplicates inside one theme (e.g. variable/plain
        // both black in Light) resolve to the same target color by design.
        let pairs: [(NSColor, NSColor)] = old.colors.compactMap { token, color in
            guard let newColor = new.colors[token] else { return nil }
            return (color, newColor)
        }
        guard !pairs.isEmpty else { return [] }

        var replacements: [(range: NSRange, color: NSColor)] = []
        storage.enumerateAttribute(.foregroundColor,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let color = value as? NSColor,
                  let mapped = pairs.first(where: { colorsMatch($0.0, color) })?.1 else {
                return
            }
            replacements.append((range, mapped))
        }
        return replacements
    }

    static func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else {
            return false
        }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
            && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }

    // MARK: View lookup

    /// The editor is added as a direct subview of the controller's view today,
    /// but a recursive lookup keeps this working if the layout nests it later.
    static func editorContainer(in view: NSView) -> EditorContainer? {
        if let editor = view as? EditorContainer { return editor }
        for subview in view.subviews {
            if let editor = editorContainer(in: subview) { return editor }
        }
        return nil
    }
}

// MARK: - Window controller

/// Native Preferences window with a segmented control across the top: simpler
/// than an NSToolbar and the same one-instance/tabbed-pane shape as System
/// Settings. Four panes: Font, Editor, Appearance, Advanced.
final class PreferencesWindowController: NSWindowController {

    /// The editor window whose text view receives live changes. The app
    /// delegate points this at its `MainWindowController` each time the window
    /// is shown; tests may leave it nil and use the appliers directly.
    weak var targetController: MainWindowController?

    private var preferences = PreferencesStore.load()

    private let paneSelector = NSSegmentedControl(labels: ["Font", "Editor", "Appearance", "Advanced"],
                                                  trackingMode: .selectOne,
                                                  target: nil,
                                                  action: nil)
    private let paneContainer = NSView()
    private var panes: [NSView] = []

    // Font pane
    private let fontFamilyPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let fontPreview = NSTextField(labelWithString: "Aa 0123 {} [] () // comment")

    // Editor pane
    private let wordWrapCheckbox = NSButton(checkboxWithTitle: "Word wrap long lines",
                                            target: nil, action: nil)
    private let autoIndentCheckbox = NSButton(checkboxWithTitle: "Auto-indent on new lines",
                                              target: nil, action: nil)
    private let autoCloseCheckbox = NSButton(checkboxWithTitle: "Auto-close brackets and quotes",
                                             target: nil, action: nil)
    private let tabSizeField = NSTextField()
    private let tabSizeStepper = NSStepper()
    private let useTabsPopup = NSPopUpButton()

    // Appearance pane
    private let themePopup = NSPopUpButton()

    // Advanced pane
    private let preferencesPathLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "Restore Defaults", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        self.init(window: window)
        buildUI()
        refreshControls()
        window.center()
    }

    /// Re-reads the file each time the window comes forward, so a change made
    /// elsewhere is reflected before the user sees the controls.
    override func showWindow(_ sender: Any?) {
        preferences = PreferencesStore.load()
        refreshControls()
        super.showWindow(sender)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        paneSelector.selectedSegment = 0
        paneSelector.target = self
        paneSelector.action = #selector(paneChanged)
        paneSelector.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(paneSelector)

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(paneContainer)

        panes = [makeFontPane(), makeEditorPane(), makeAppearancePane(), makeAdvancedPane()]
        for (index, pane) in panes.enumerated() {
            pane.translatesAutoresizingMaskIntoConstraints = false
            paneContainer.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
                pane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
                pane.bottomAnchor.constraint(lessThanOrEqualTo: paneContainer.bottomAnchor)
            ])
            pane.isHidden = index != 0
        }

        NSLayoutConstraint.activate([
            paneSelector.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            paneSelector.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            paneContainer.topAnchor.constraint(equalTo: paneSelector.bottomAnchor, constant: 16),
            paneContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            paneContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            paneContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            paneContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
    }

    private func makePane() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 480
        return label
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func makeFontPane() -> NSView {
        let pane = makePane()
        pane.addArrangedSubview(sectionLabel("Editor Font"))

        fontFamilyPopup.addItems(withTitles: Self.monospacedFamilies())
        fontFamilyPopup.target = self
        fontFamilyPopup.action = #selector(fontFamilyChanged)
        fontFamilyPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        pane.addArrangedSubview(row("Family:", fontFamilyPopup))

        fontSizeField.alignment = .right
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeChanged)
        let sizeFormatter = NumberFormatter()
        sizeFormatter.allowsFloats = false
        sizeFormatter.minimum = NSNumber(value: Double(Preferences.fontSizeRange.lowerBound))
        sizeFormatter.maximum = NSNumber(value: Double(Preferences.fontSizeRange.upperBound))
        fontSizeField.formatter = sizeFormatter
        fontSizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true

        fontSizeStepper.minValue = Double(Preferences.fontSizeRange.lowerBound)
        fontSizeStepper.maxValue = Double(Preferences.fontSizeRange.upperBound)
        fontSizeStepper.increment = 1
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeChanged)

        let sizeRow = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 4
        pane.addArrangedSubview(row("Size:", sizeRow))

        fontPreview.maximumNumberOfLines = 1
        fontPreview.lineBreakMode = .byTruncatingTail
        fontPreview.textColor = .labelColor
        pane.addArrangedSubview(fontPreview)

        pane.addArrangedSubview(hintLabel("Family and size apply to the active editor immediately. "
            + "Files opened later inherit the same font."))
        return pane
    }

    private func makeEditorPane() -> NSView {
        let pane = makePane()
        pane.addArrangedSubview(sectionLabel("Editor Behavior"))

        for checkbox in [wordWrapCheckbox, autoIndentCheckbox, autoCloseCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(editorCheckboxChanged)
            pane.addArrangedSubview(checkbox)
        }

        tabSizeField.alignment = .right
        tabSizeField.target = self
        tabSizeField.action = #selector(tabSizeChanged)
        let tabFormatter = NumberFormatter()
        tabFormatter.allowsFloats = false
        tabFormatter.minimum = NSNumber(value: Preferences.tabSizeRange.lowerBound)
        tabFormatter.maximum = NSNumber(value: Preferences.tabSizeRange.upperBound)
        tabSizeField.formatter = tabFormatter
        tabSizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true

        tabSizeStepper.minValue = Double(Preferences.tabSizeRange.lowerBound)
        tabSizeStepper.maxValue = Double(Preferences.tabSizeRange.upperBound)
        tabSizeStepper.increment = 1
        tabSizeStepper.target = self
        tabSizeStepper.action = #selector(tabSizeChanged)

        let tabRow = NSStackView(views: [tabSizeField, tabSizeStepper])
        tabRow.orientation = .horizontal
        tabRow.spacing = 4
        pane.addArrangedSubview(row("Tab width:", tabRow))

        useTabsPopup.addItems(withTitles: ["Spaces", "Tabs"])
        useTabsPopup.target = self
        useTabsPopup.action = #selector(useTabsChanged)
        pane.addArrangedSubview(row("Indent with:", useTabsPopup))

        pane.addArrangedSubview(hintLabel("Word wrap applies to the active editor immediately and "
            + "becomes the default for new documents. Each open document keeps its own setting. "
            + "Auto-indent, auto-close, tab width, and the spaces/tabs choice are saved now and "
            + "will be wired into the editor in the follow-up slice."))
        return pane
    }

    private func makeAppearancePane() -> NSView {
        let pane = makePane()
        pane.addArrangedSubview(sectionLabel("Syntax Theme"))

        themePopup.addItems(withTitles: HexpadTheme.allCases.map(\.rawValue))
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        themePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        pane.addArrangedSubview(row("Theme:", themePopup))

        pane.addArrangedSubview(hintLabel("The chosen theme repaints the active editor's token "
            + "colors immediately and is reused for every tab, including after a relaunch."))
        return pane
    }

    private func makeAdvancedPane() -> NSView {
        let pane = makePane()
        pane.addArrangedSubview(sectionLabel("Advanced"))

        let threshold = NumberFormatter.localizedString(
            from: NSNumber(value: TokenStore.largeFileThreshold), number: .decimal)
        let thresholdLabel = NSTextField(labelWithString: "Large-file threshold: \(threshold) characters")
        pane.addArrangedSubview(thresholdLabel)
        pane.addArrangedSubview(hintLabel("Files larger than this are highlighted viewport-only. "
            + "This limit is fixed in the current release; it is shown here for reference."))

        preferencesPathLabel.stringValue = PreferencesStore.preferencesFileURL.path
        preferencesPathLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        preferencesPathLabel.textColor = .secondaryLabelColor
        preferencesPathLabel.lineBreakMode = .byTruncatingMiddle
        preferencesPathLabel.maximumNumberOfLines = 1
        preferencesPathLabel.isSelectable = true
        preferencesPathLabel.toolTip = PreferencesStore.preferencesFileURL.path
        pane.addArrangedSubview(preferencesPathLabel)

        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetToDefaults)
        pane.addArrangedSubview(resetButton)

        pane.addArrangedSubview(hintLabel("Preferences are stored as JSON in Application Support."))
        return pane
    }

    // MARK: - Control state

    private func refreshControls() {
        let families = Self.monospacedFamilies()
        if !families.contains(preferences.fontFamily) {
            preferences.fontFamily = families.first ?? Preferences.defaults.fontFamily
        }
        fontFamilyPopup.selectItem(withTitle: preferences.fontFamily)

        fontSizeField.doubleValue = Double(preferences.fontSize)
        fontSizeStepper.doubleValue = Double(preferences.fontSize)
        updateFontPreview()

        wordWrapCheckbox.state = preferences.wordWrap ? .on : .off
        autoIndentCheckbox.state = preferences.autoIndent ? .on : .off
        autoCloseCheckbox.state = preferences.autoCloseBrackets ? .on : .off
        tabSizeField.integerValue = preferences.tabSize
        tabSizeStepper.integerValue = preferences.tabSize
        useTabsPopup.selectItem(at: preferences.useTabs ? 1 : 0)

        themePopup.selectItem(withTitle: preferences.selectedTheme.rawValue)
        preferencesPathLabel.stringValue = PreferencesStore.preferencesFileURL.path
    }

    private func updateFontPreview() {
        fontPreview.font = PreferencesApplier.resolvedFont(family: preferences.fontFamily,
                                                           size: preferences.fontSize)
    }

    @objc private func paneChanged() {
        for (index, pane) in panes.enumerated() {
            pane.isHidden = index != paneSelector.selectedSegment
        }
    }

    // MARK: - Actions

    @objc private func fontFamilyChanged() {
        guard let family = fontFamilyPopup.titleOfSelectedItem else { return }
        persist(options: .font) { $0.fontFamily = family }
    }

    @objc private func fontSizeChanged(_ sender: NSControl) {
        let value = sender === fontSizeStepper ? fontSizeStepper.doubleValue
                                               : fontSizeField.doubleValue
        persist(options: .font) { $0.fontSize = CGFloat(value) }
    }

    @objc private func editorCheckboxChanged() {
        persist(options: .wrap) {
            $0.wordWrap = wordWrapCheckbox.state == .on
            $0.autoIndent = autoIndentCheckbox.state == .on
            $0.autoCloseBrackets = autoCloseCheckbox.state == .on
        }
    }

    @objc private func tabSizeChanged(_ sender: NSControl) {
        let value = sender === tabSizeStepper ? tabSizeStepper.integerValue
                                              : tabSizeField.integerValue
        persist { $0.tabSize = value }
    }

    @objc private func useTabsChanged() {
        persist { $0.useTabs = useTabsPopup.indexOfSelectedItem == 1 }
    }

    @objc private func themeChanged() {
        guard let raw = themePopup.titleOfSelectedItem else { return }
        persist(options: .theme) { $0.theme = raw }
    }

    @objc private func resetToDefaults() {
        do {
            try PreferencesStore.resetToDefaults()
            preferences = .defaults
            refreshControls()
            PreferencesApplier.apply(preferences, to: resolvedTargetController())
        } catch {
            showError(error)
        }
    }

    // MARK: - Persistence

    private func persist(options: PreferencesApplier.Options = [],
                         _ mutate: (inout Preferences) -> Void) {
        do {
            preferences = try PreferencesStore.update(mutate)
            refreshControls()
            PreferencesApplier.apply(preferences,
                                     to: resolvedTargetController(),
                                     options: options)
        } catch {
            showError(error)
        }
    }

    /// The controller the delegate handed us, or the only document window when
    /// the window controller is used standalone.
    private func resolvedTargetController() -> MainWindowController? {
        if let targetController { return targetController }
        return NSApp.windows.lazy.compactMap { $0.contentViewController as? MainWindowController }.first
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Save Preferences"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Font families

    /// Installed fixed-pitch families, with the defaults guaranteed present.
    /// `NSFontManager` knows which installed faces are monospaced, so the list
    /// stays useful on machines with extra coding fonts installed.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        var families = manager.availableFontFamilies.filter { family in
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 12) else {
                return false
            }
            return manager.traits(of: font).contains(.fixedPitchFontMask)
        }

        for required in ["Menlo", "Monaco", "Courier New"] where !families.contains(required) {
            if manager.availableFontFamilies.contains(required) {
                families.append(required)
            }
        }
        if families.isEmpty {
            families = [Preferences.defaults.fontFamily]
        }
        return families.sorted()
    }
}
