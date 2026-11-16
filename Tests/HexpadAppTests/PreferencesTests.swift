import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Coverage for the preferences store and the live editor application layer:
/// persistence, per-key defaults, malformed-file tolerance, theme repainting,
/// and word-wrap application.
final class PreferencesTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-preferences-tests-\(UUID().uuidString)")
        PreferencesStore.overrideDirectory = directory
    }

    override func tearDownWithError() throws {
        PreferencesStore.overrideDirectory = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func writePreferences(_ json: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: PreferencesStore.preferencesFileURL)
    }

    private func foregroundColor(of textView: NSTextView, at index: Int) -> NSColor? {
        textView.textStorage?.attribute(.foregroundColor,
                                        at: index,
                                        effectiveRange: nil) as? NSColor
    }

    // MARK: - Defaults

    func testDefaultsForEveryKeyWhenFileMissing() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: PreferencesStore.preferencesFileURL.path))

        let loaded = PreferencesStore.load()
        XCTAssertEqual(loaded, Preferences.defaults)

        // Spell every key out so a changed default is a deliberate edit.
        XCTAssertEqual(loaded.fontFamily, "Menlo")
        XCTAssertEqual(loaded.fontSize, 13)
        XCTAssertFalse(loaded.wordWrap)
        XCTAssertTrue(loaded.autoIndent)
        XCTAssertFalse(loaded.autoCloseBrackets)
        XCTAssertEqual(loaded.tabSize, 4)
        XCTAssertFalse(loaded.useTabs)
        XCTAssertEqual(loaded.theme, ThemePreference.system.rawValue)
    }

    // MARK: - Round trip

    func testSaveLoadRoundTrip() throws {
        var preferences = Preferences.defaults
        preferences.fontFamily = "Monaco"
        preferences.fontSize = 17
        preferences.wordWrap = true
        preferences.autoIndent = false
        preferences.autoCloseBrackets = true
        preferences.tabSize = 2
        preferences.useTabs = true
        preferences.theme = HexpadTheme.monokai.rawValue

        try PreferencesStore.save(preferences)

        XCTAssertEqual(PreferencesStore.preferencesFileURL.lastPathComponent, "preferences.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: PreferencesStore.preferencesFileURL.path))

        // A fresh load stands in for a relaunch: no in-memory state is kept.
        XCTAssertEqual(PreferencesStore.load(), preferences)
        XCTAssertEqual(PreferencesStore.load().selectedTheme, .monokai)
    }

    func testSaveNormalizesOutOfRangeValuesBeforeWriting() throws {
        var preferences = Preferences.defaults
        preferences.fontSize = 500
        preferences.tabSize = 0

        let saved = try PreferencesStore.save(preferences)
        XCTAssertEqual(saved.fontSize, Preferences.fontSizeRange.upperBound)
        XCTAssertEqual(saved.tabSize, Preferences.tabSizeRange.lowerBound)
        XCTAssertEqual(PreferencesStore.load(), saved)
    }

    // MARK: - System theme and migration

    func testDefaultThemeIsSystem() {
        XCTAssertEqual(Preferences.defaults.themePreference, .system)
        XCTAssertNil(Preferences.defaults.selectedTheme,
                     "System has no explicit palette; it resolves from appearance")
    }

    func testExplicitLightSurvivesSaveAndReload() throws {
        var preferences = Preferences.defaults
        preferences.theme = ThemePreference.light.rawValue
        try PreferencesStore.save(preferences)

        let loaded = PreferencesStore.load()
        XCTAssertEqual(loaded.themePreference, .light,
                       "a versioned save keeps an explicit Light choice")
        XCTAssertEqual(loaded.selectedTheme, .light)
    }

    func testLegacyFileWithoutThemeKeyMigratesToSystem() throws {
        try writePreferences(#"{ "wordWrap": true, "fontSize": 15 }"#)

        let loaded = PreferencesStore.load()
        XCTAssertEqual(loaded.themePreference, .system)
        XCTAssertTrue(loaded.wordWrap, "other legacy keys survive the migration")
    }

    func testLegacyLightDefaultMigratesToSystem() throws {
        // The previous build always wrote "Light" because that was its default
        // and had no version marker, so Light cannot be distinguished from an
        // implicit default. It upgrades to System, which paints identically in
        // light appearance and correctly follows dark appearance.
        try writePreferences(#"{ "theme": "Light", "fontSize": 15 }"#)

        let loaded = PreferencesStore.load()
        XCTAssertEqual(loaded.themePreference, .system)
        XCTAssertEqual(loaded.fontSize, 15)
    }

    func testLegacyNamedThemesArePreserved() throws {
        for legacy in [HexpadTheme.dark, .classic, .monokai] {
            try writePreferences(#"{ "theme": "\#(legacy.rawValue)" }"#)

            XCTAssertEqual(PreferencesStore.load().themePreference,
                           ThemePreference(rawValue: legacy.rawValue),
                           "an existing \(legacy.rawValue) choice is not reset to System")
        }
    }

    func testLegacyUnknownThemeMigratesToSystem() throws {
        try writePreferences(#"{ "theme": "Solarized" }"#)

        XCTAssertEqual(PreferencesStore.load().themePreference, .system,
                       "contract change: unknown themes now fall back to System, not Light")
    }

    // MARK: - Malformed files

    func testMalformedFileFallsBackToDefaults() throws {
        try writePreferences("this is not json")

        XCTAssertEqual(PreferencesStore.load(), Preferences.defaults)
    }

    func testWrongTypeForOneKeyKeepsOtherKeys() throws {
        try writePreferences("""
        {
          "fontFamily": "Menlo",
          "fontSize": "huge",
          "wordWrap": true,
          "autoIndent": false,
          "tabSize": "two",
          "theme": "Solarized"
        }
        """)

        let loaded = PreferencesStore.load()
        XCTAssertEqual(loaded.fontFamily, "Menlo")
        XCTAssertEqual(loaded.fontSize, Preferences.defaults.fontSize, "unreadable size falls back")
        XCTAssertTrue(loaded.wordWrap, "valid keys survive a sibling type error")
        XCTAssertFalse(loaded.autoIndent)
        XCTAssertEqual(loaded.tabSize, Preferences.defaults.tabSize, "unreadable tab size falls back")
        XCTAssertEqual(loaded.theme, Preferences.defaults.theme, "unknown theme falls back")
        XCTAssertFalse(loaded.autoCloseBrackets, "missing key falls back")
    }

    func testMissingKeysInsideValidObjectFallBackIndividually() throws {
        try writePreferences(#"{ "wordWrap": true, "fontSize": 15 }"#)

        let loaded = PreferencesStore.load()
        XCTAssertTrue(loaded.wordWrap)
        XCTAssertEqual(loaded.fontSize, 15)
        XCTAssertEqual(loaded.fontFamily, Preferences.defaults.fontFamily)
        XCTAssertEqual(loaded.autoIndent, Preferences.defaults.autoIndent)
        XCTAssertEqual(loaded.tabSize, Preferences.defaults.tabSize)
        XCTAssertEqual(loaded.theme, Preferences.defaults.theme)
    }

    func testOutOfRangeNumbersAreClamped() throws {
        try writePreferences(#"{ "fontSize": 200, "tabSize": -5 }"#)

        let loaded = PreferencesStore.load()
        XCTAssertEqual(loaded.fontSize, Preferences.fontSizeRange.upperBound)
        XCTAssertEqual(loaded.tabSize, Preferences.tabSizeRange.lowerBound)
    }

    // MARK: - Notification

    func testSavingPostsPreferencesDidChange() throws {
        var preferences = Preferences.defaults
        preferences.wordWrap = true

        let changed = expectation(description: "preferencesDidChange posted")
        let token = NotificationCenter.default.addObserver(forName: .preferencesDidChange,
                                                           object: nil,
                                                           queue: nil) { notification in
            XCTAssertEqual(notification.object as? Preferences, preferences)
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try PreferencesStore.save(preferences)
        wait(for: [changed], timeout: 1)
    }

    func testResetRemovesFileAndRestoresDefaults() throws {
        var preferences = Preferences.defaults
        preferences.theme = HexpadTheme.monokai.rawValue
        try PreferencesStore.save(preferences)

        try PreferencesStore.resetToDefaults()

        XCTAssertFalse(FileManager.default.fileExists(atPath: PreferencesStore.preferencesFileURL.path))
        XCTAssertEqual(PreferencesStore.load(), Preferences.defaults)
    }

    // MARK: - Live application

    func testSystemPreferenceResolvesThroughEffectiveAppearance() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))

        XCTAssertEqual(ThemePreference.system.resolvedTheme(for: dark), .dark,
                       "System under a dark appearance selects the dark palette")
        XCTAssertEqual(ThemePreference.system.resolvedTheme(for: light), .light)
    }

    func testExplicitPreferenceWinsOverAppearance() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))

        XCTAssertEqual(ThemePreference.monokai.resolvedTheme(for: dark), .monokai)
        XCTAssertEqual(ThemePreference.light.resolvedTheme(for: dark), .light,
                       "an explicit Light choice ignores a dark appearance")
        XCTAssertEqual(ThemePreference.classic.resolvedTheme(for: light), .classic)
    }

    func testApplyingSystemThemeUsesTextViewAppearance() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.string = "let answer = 1"
        textView.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        // Start from an explicitly Light-painted view so the pass has to
        // resolve the appearance and remap the token color, not just flip a
        // background property.
        let light = HexpadTheme.light.theme
        textView.backgroundColor = light.background
        let keywordRange = (textView.string as NSString).range(of: "let")
        textView.textStorage?.addAttribute(.foregroundColor,
                                           value: try XCTUnwrap(light.colors[.keyword]),
                                           range: keywordRange)

        PreferencesApplier.applyTheme(.system, to: textView)

        let dark = HexpadTheme.dark.theme
        XCTAssertTrue(PreferencesApplier.colorsMatch(try XCTUnwrap(textView.backgroundColor),
                                                      dark.background),
                      "System paints the appearance-derived background")
        let keyword = try XCTUnwrap(foregroundColor(of: textView, at: keywordRange.location))
        XCTAssertTrue(PreferencesApplier.colorsMatch(keyword,
                                                      try XCTUnwrap(dark.colors[.keyword])),
                      "System paints the dark token palette")
    }

    func testThemeChangeUpdatesEditorColors() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.string = "let answer = 1 // note"

        let light = HexpadTheme.light.theme
        let monokai = HexpadTheme.monokai.theme
        textView.backgroundColor = light.background

        let keywordRange = (textView.string as NSString).range(of: "let")
        let commentRange = (textView.string as NSString).range(of: "// note")
        let lightKeyword = try XCTUnwrap(light.colors[.keyword])
        let monokaiKeyword = try XCTUnwrap(monokai.colors[.keyword])
        XCTAssertFalse(PreferencesApplier.colorsMatch(lightKeyword, monokaiKeyword),
                       "test needs visibly different keyword colors")

        textView.textStorage?.addAttribute(.foregroundColor, value: lightKeyword, range: keywordRange)
        textView.textStorage?.addAttribute(.foregroundColor,
                                           value: try XCTUnwrap(light.colors[.comment]),
                                           range: commentRange)

        PreferencesApplier.applyTheme(HexpadTheme.monokai, to: textView)

        let updatedKeyword = try XCTUnwrap(foregroundColor(of: textView, at: keywordRange.location))
        XCTAssertTrue(PreferencesApplier.colorsMatch(updatedKeyword, monokaiKeyword),
                      "keyword token adopts the Monokai palette")
        let updatedComment = try XCTUnwrap(foregroundColor(of: textView, at: commentRange.location))
        XCTAssertTrue(PreferencesApplier.colorsMatch(updatedComment,
                                                      try XCTUnwrap(monokai.colors[.comment])),
                      "comment token adopts the Monokai palette")

        XCTAssertTrue(PreferencesApplier.colorsMatch(try XCTUnwrap(textView.backgroundColor),
                                                      monokai.background))
        XCTAssertEqual(PreferencesApplier.detectedTheme(of: textView), .monokai)
    }

    func testWordWrapPreferenceIsReadAndApplied() throws {
        var preferences = Preferences.defaults
        preferences.wordWrap = true
        try PreferencesStore.save(preferences)

        XCTAssertTrue(PreferencesStore.load().wordWrap)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.isHorizontallyResizable = true
        PreferencesApplier.applyWordWrap(true, to: textView)
        XCTAssertFalse(textView.isHorizontallyResizable)

        PreferencesApplier.applyWordWrap(false, to: textView)
        XCTAssertTrue(textView.isHorizontallyResizable)
    }

    func testFontPreferenceResolvesMonospacedFont() {
        let font = PreferencesApplier.resolvedFont(family: "Menlo", size: 18)
        XCTAssertEqual(font.pointSize, 18)

        // A missing family still yields a usable fixed-pitch font.
        let fallback = PreferencesApplier.resolvedFont(family: "Not An Installed Font", size: 11)
        XCTAssertEqual(fallback.pointSize, 11)
        XCTAssertTrue(NSFontManager.shared.traits(of: fallback).contains(.fixedPitchFontMask))
    }

    func testEditorContainerLookupFindsLiveTextView() throws {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view

        let editor = try XCTUnwrap(PreferencesApplier.editorContainer(in: controller.view))
        XCTAssertTrue(editor.textView === controller.editorTextView)

        PreferencesApplier.apply(.defaults, to: controller)
        XCTAssertEqual(editor.bodyFont.pointSize, Preferences.defaults.fontSize)
    }

    // MARK: - Window

    func testPreferencesWindowBuildsAndShows() throws {
        let controller = PreferencesWindowController()
        defer {
            controller.close()
        }

        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, "Preferences")
        XCTAssertFalse(window.isReleasedWhenClosed, "the delegate reuses this window")

        controller.showWindow(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(window.contentView)
    }

    // MARK: - Menu integration

    func testPreferencesMenuItemUsesCommandComma() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        // AppKit renames the item to "Settings…" on macOS 13+, so locate the
        // standard slot by key equivalent rather than by localized title.
        let item = try XCTUnwrap(appMenu.items.first { $0.keyEquivalent == "," })

        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(item.isEnabled, "Cmd+, must be reachable")
        XCTAssertNotNil(item.action)
        XCTAssertTrue(["Preferences…", "Settings…"].contains(item.title), item.title)
    }
}
