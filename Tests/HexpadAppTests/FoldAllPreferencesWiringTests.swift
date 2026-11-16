import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Coverage for the two final W-batch controller features:
///
/// 1. View > Fold All / Unfold All route through `EditorContainer` and
///    `FoldModel`, persist into `DocumentModel.foldState`, and validate against
///    the selected document's foldable ranges.
/// 2. Persisted preferences apply at startup and on every tab bind, without
///    overwriting per-document caret/wrap state, and a live theme preference
///    change repaints token colors.
final class FoldAllMenuTests: XCTestCase {

    /// Two nested brace folds: outer on line 1, inner on line 2.
    private let foldableText = "outer {\n    inner {\n        x\n    }\n}\ntail\n"

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    private func makeSwiftDocument(in controller: MainWindowController) throws -> DocumentModel {
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.setLanguage(Language.swift.rawValue)
        doc.replaceAllText(with: foldableText)
        controller.updateEditor()
        return doc
    }

    func testFoldAllTogglesEveryMarkerAndWritesThroughToFoldState() throws {
        let (controller, _) = makeController()
        let editor = try XCTUnwrap(PreferencesApplier.editorContainer(in: controller.view))
        let doc = try makeSwiftDocument(in: controller)

        XCTAssertEqual(Set(editor.foldMarkers.keys), [1, 2])
        XCTAssertTrue(doc.foldState.isEmpty)
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty)

        controller.foldAll(nil)

        XCTAssertEqual(editor.foldMarkers[1], .collapsed)
        XCTAssertEqual(editor.foldMarkers[2], .collapsed,
                       "nested marker state is retained while hidden")
        XCTAssertEqual(doc.foldState.count, 2)
        XCTAssertEqual(doc.foldState, editor.foldModel?.foldState,
                       "the persisted projection must match the live fold model")
        XCTAssertFalse(editor.foldHiddenRanges.isEmpty)

        controller.unfoldAll(nil)

        XCTAssertEqual(editor.foldMarkers[1], .expanded)
        XCTAssertEqual(editor.foldMarkers[2], .expanded)
        XCTAssertTrue(doc.foldState.isEmpty)
        XCTAssertEqual(doc.foldState, editor.foldModel?.foldState)
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty)
    }

    func testFoldAllIsDisabledWithoutDocumentOrFoldableRanges() throws {
        let (controller, _) = makeController()
        let foldItem = NSMenuItem(title: "Fold All",
                                  action: #selector(MainWindowController.foldAll(_:)),
                                  keyEquivalent: "")
        let unfoldItem = NSMenuItem(title: "Unfold All",
                                    action: #selector(MainWindowController.unfoldAll(_:)),
                                    keyEquivalent: "")

        // The default tab is plain text: no document structure to fold.
        XCTAssertFalse(controller.canFoldAll())
        XCTAssertFalse(controller.canUnfoldAll())
        XCTAssertFalse(controller.validateMenuItem(foldItem))
        XCTAssertFalse(controller.validateMenuItem(unfoldItem))

        _ = try makeSwiftDocument(in: controller)

        XCTAssertTrue(controller.canFoldAll())
        XCTAssertTrue(controller.canUnfoldAll())
        XCTAssertTrue(controller.validateMenuItem(foldItem))
        XCTAssertTrue(controller.validateMenuItem(unfoldItem))

        // No document at all is also disabled even though the model still
        // holds a foldable buffer.
        controller.tabStore.documents.removeAll()
        controller.updateEditor()
        XCTAssertFalse(controller.canFoldAll())
        XCTAssertFalse(controller.canUnfoldAll())
        XCTAssertFalse(controller.validateMenuItem(foldItem))
        XCTAssertFalse(controller.validateMenuItem(unfoldItem))
    }

    func testViewMenuWiresFoldAllAndUnfoldAllThroughTheResponderChain() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)

        let foldAll = try XCTUnwrap(viewMenu.item(withTitle: "Fold All"))
        XCTAssertNil(foldAll.target, "validation reaches the controller via the responder chain")
        XCTAssertEqual(foldAll.action, #selector(MainWindowController.foldAll(_:)))
        XCTAssertEqual(foldAll.keyEquivalent, "0", "N++ Fold All is Alt+0")
        XCTAssertEqual(foldAll.keyEquivalentModifierMask, [.option])

        let unfoldAll = try XCTUnwrap(viewMenu.item(withTitle: "Unfold All"))
        XCTAssertNil(unfoldAll.target)
        XCTAssertEqual(unfoldAll.action, #selector(MainWindowController.unfoldAll(_:)))
        XCTAssertEqual(unfoldAll.keyEquivalent, "0", "N++ Unfold All is Alt+Shift+0")
        XCTAssertEqual(unfoldAll.keyEquivalentModifierMask, [.option, .shift])

        let titles = viewMenu.items.map(\.title)
        let functionListIndex = try XCTUnwrap(titles.firstIndex(of: "Function List"))
        let foldAllIndex = try XCTUnwrap(titles.firstIndex(of: "Fold All"))
        let unfoldAllIndex = try XCTUnwrap(titles.firstIndex(of: "Unfold All"))
        XCTAssertLessThan(functionListIndex, foldAllIndex)
        XCTAssertLessThan(foldAllIndex, unfoldAllIndex)
    }
}

final class PreferencesStartupApplyTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-startup-prefs-\(UUID().uuidString)")
        PreferencesStore.overrideDirectory = directory
    }

    override func tearDownWithError() throws {
        PreferencesStore.overrideDirectory = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    private func foregroundColor(of textView: NSTextView, at index: Int) -> NSColor? {
        textView.textStorage?.attribute(.foregroundColor,
                                        at: index,
                                        effectiveRange: nil) as? NSColor
    }

    // MARK: - Startup defaults

    func testPersistedPreferencesApplyOnStartup() throws {
        var preferences = Preferences.defaults
        preferences.fontSize = 17
        preferences.wordWrap = true
        try PreferencesStore.save(preferences)

        let (controller, _) = makeController()
        let textView = try XCTUnwrap(controller.editorTextView)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)

        XCTAssertEqual(textView.font?.pointSize, 17,
                       "the persisted font applies to the first editor")
        XCTAssertFalse(textView.isHorizontallyResizable,
                       "a new document inherits the wrap default")
        XCTAssertTrue(doc.wordWrapEnabled,
                      "the preference seeds the document's per-document state")
    }

    func testPreferencesApplyOnBindWithoutClobberingRestoredCaretOrWrap() throws {
        var preferences = Preferences.defaults
        preferences.fontSize = 18
        preferences.wordWrap = true
        try PreferencesStore.save(preferences)

        let (controller, _) = makeController()
        let textView = try XCTUnwrap(controller.editorTextView)

        // A restored document: its caret and per-document wrap already exist.
        let text = (0..<120).map { "line \($0)" }.joined(separator: "\n")
        let restored = DocumentModel(text: text)
        restored.caretRange = NSRange(location: 55, length: 0)
        restored.wordWrapEnabled = false

        controller.tabStore.addDocument(restored)
        controller.updateEditor()

        XCTAssertEqual(textView.font?.pointSize, 18,
                       "the font preference still applies on bind")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 55, length: 0),
                       "applying preferences must not move a restored caret")
        XCTAssertEqual(restored.caretRange, NSRange(location: 55, length: 0))
        XCTAssertTrue(textView.isHorizontallyResizable,
                      "the document's persisted wrap wins over the preference")
        XCTAssertFalse(restored.wordWrapEnabled)
    }

    // MARK: - Live theme changes

    func testThemePreferenceChangeRehighlightsTokenColors() throws {
        var preferences = Preferences.defaults
        preferences.theme = HexpadTheme.light.rawValue
        try PreferencesStore.save(preferences)

        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.setLanguage(Language.swift.rawValue)
        doc.replaceAllText(with: "func f() {\n    let x = 1\n}\n")
        controller.updateEditor()

        let textView = try XCTUnwrap(controller.editorTextView)
        let keywordRange = (textView.string as NSString).range(of: "func")
        let lightKeyword = try XCTUnwrap(HexpadTheme.light.theme.colors[.keyword])
        let monokaiKeyword = try XCTUnwrap(HexpadTheme.monokai.theme.colors[.keyword])
        XCTAssertFalse(PreferencesApplier.colorsMatch(lightKeyword, monokaiKeyword),
                       "test needs visibly different keyword colors")

        let initial = try XCTUnwrap(foregroundColor(of: textView, at: keywordRange.location))
        XCTAssertTrue(PreferencesApplier.colorsMatch(initial, lightKeyword),
                      "the startup preference paints Light token colors")

        // Saving posts .preferencesDidChange synchronously; the controller
        // must repaint with the new palette without a tab switch.
        preferences.theme = HexpadTheme.monokai.rawValue
        try PreferencesStore.save(preferences)

        let updated = try XCTUnwrap(foregroundColor(of: textView, at: keywordRange.location))
        XCTAssertTrue(PreferencesApplier.colorsMatch(updated, monokaiKeyword),
                      "a live theme change re-highlights the keyword token")
        XCTAssertTrue(PreferencesApplier.colorsMatch(try XCTUnwrap(textView.backgroundColor),
                                                      HexpadTheme.monokai.theme.background))
    }

    func testSystemThemeRepaintsWhenEffectiveAppearanceChanges() throws {
        // A fresh install keeps the default System preference. The palette must
        // come from the editor's effective appearance, and an appearance change
        // must repaint both chrome and token colors.
        try PreferencesStore.save(.defaults)

        let (controller, _) = makeController()
        let editor = try XCTUnwrap(PreferencesApplier.editorContainer(in: controller.view))
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.setLanguage(Language.swift.rawValue)
        doc.replaceAllText(with: "func f() {\n    let x = 1\n}\n")
        controller.updateEditor()

        let textView = try XCTUnwrap(controller.editorTextView)
        let keywordRange = (textView.string as NSString).range(of: "func")
        let light = HexpadTheme.light.theme
        let dark = HexpadTheme.dark.theme
        let lightKeyword = try XCTUnwrap(light.colors[.keyword])
        let darkKeyword = try XCTUnwrap(dark.colors[.keyword])
        XCTAssertFalse(PreferencesApplier.colorsMatch(lightKeyword, darkKeyword),
                       "test needs visibly different keyword colors")

        editor.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        editor.viewDidChangeEffectiveAppearance()

        XCTAssertTrue(PreferencesApplier.colorsMatch(
            try XCTUnwrap(foregroundColor(of: textView, at: keywordRange.location)),
            lightKeyword), "System in light appearance paints Light tokens")
        XCTAssertTrue(PreferencesApplier.colorsMatch(try XCTUnwrap(textView.backgroundColor),
                                                      light.background))

        editor.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        editor.viewDidChangeEffectiveAppearance()

        XCTAssertTrue(PreferencesApplier.colorsMatch(
            try XCTUnwrap(foregroundColor(of: textView, at: keywordRange.location)),
            darkKeyword), "handleAppearanceChange re-resolves System to the dark palette")
        XCTAssertTrue(PreferencesApplier.colorsMatch(try XCTUnwrap(textView.backgroundColor),
                                                      dark.background),
                      "the editor background follows the appearance, not a white default")
    }

    func testExplicitThemeWinsOverAppearanceOnController() throws {
        var preferences = Preferences.defaults
        preferences.theme = ThemePreference.monokai.rawValue
        try PreferencesStore.save(preferences)

        let (controller, _) = makeController()
        let editor = try XCTUnwrap(PreferencesApplier.editorContainer(in: controller.view))
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.setLanguage(Language.swift.rawValue)
        doc.replaceAllText(with: "func f() {\n    let x = 1\n}\n")
        editor.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        controller.updateEditor()

        let textView = try XCTUnwrap(controller.editorTextView)
        let keywordRange = (textView.string as NSString).range(of: "func")
        let monokai = HexpadTheme.monokai.theme
        XCTAssertTrue(PreferencesApplier.colorsMatch(
            try XCTUnwrap(foregroundColor(of: textView, at: keywordRange.location)),
            try XCTUnwrap(monokai.colors[.keyword])),
            "an explicit theme ignores the dark appearance")
        XCTAssertTrue(PreferencesApplier.colorsMatch(try XCTUnwrap(textView.backgroundColor),
                                                      monokai.background))
    }
}
