import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Coverage for the user keybinding override store: persistence, menu
/// application, reset, and malformed-file tolerance.
final class KeybindingStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-keybinding-tests-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = directory
    }

    override func tearDownWithError() throws {
        KeybindingStore.overrideDirectory = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        return controller
    }

    private func commandItem(_ identifier: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first {
            $0.action == #selector(MainWindowController.performCommand(withIdentifier:))
                && ($0.representedObject as? String) == identifier
        }
    }

    private func textMenu() throws -> NSMenu {
        let menu = HexpadAppDelegate().buildMainMenu()
        let textItem = try XCTUnwrap(menu.item(withTitle: "Text"))
        return try XCTUnwrap(textItem.submenu)
    }

    private func validationItem(_ identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: identifier,
                              action: #selector(MainWindowController.performCommand(withIdentifier:)),
                              keyEquivalent: "")
        item.representedObject = identifier
        return item
    }

    // MARK: - Persistence

    func testOverrideSaveLoadRoundTrip() throws {
        let binding = EditorCommandBinding(identifier: "duplicate-line",
                                           keyEquivalent: "j",
                                           modifierMask: [.command, .option])
        try KeybindingStore.setOverride(binding)

        XCTAssertEqual(KeybindingStore.overridesFileURL.lastPathComponent, "keybindings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: KeybindingStore.overridesFileURL.path))

        // A fresh load stands in for a relaunch: no in-memory state is kept.
        let loaded = KeybindingStore.loadOverrides()
        XCTAssertEqual(loaded["duplicate-line"]?.keyEquivalent, "j")
        XCTAssertEqual(loaded["duplicate-line"]?.modifierMask, [.command, .option])

        let resolved = try XCTUnwrap(KeybindingStore.resolvedBinding(for: "duplicate-line"))
        XCTAssertEqual(resolved.keyEquivalent, "j")
        XCTAssertEqual(resolved.modifierMask, [.command, .option])

        // Commands without an override still resolve to their defaults.
        let untouched = try XCTUnwrap(KeybindingStore.resolvedBinding(for: "delete-line"))
        XCTAssertEqual(untouched.keyEquivalent, "d")
        XCTAssertEqual(untouched.modifierMask, [.command, .shift])
    }

    func testRemoveOverrideRestoresDefaultBinding() throws {
        try KeybindingStore.setOverride(EditorCommandBinding(identifier: "uppercase",
                                                             keyEquivalent: "k",
                                                             modifierMask: [.command, .control]))
        XCTAssertEqual(KeybindingStore.loadOverrides()["uppercase"]?.keyEquivalent, "k")

        try KeybindingStore.removeOverride(for: "uppercase")

        XCTAssertNil(KeybindingStore.loadOverrides()["uppercase"])
        let resolved = try XCTUnwrap(KeybindingStore.resolvedBinding(for: "uppercase"))
        XCTAssertEqual(resolved.keyEquivalent, "u")
        XCTAssertEqual(resolved.modifierMask, [.command, .shift])
    }

    func testOverrideChangesPostNotification() throws {
        let changed = expectation(description: "keybindings changed")
        changed.expectedFulfillmentCount = 2
        let token = NotificationCenter.default.addObserver(forName: .keybindingsDidChange,
                                                           object: nil,
                                                           queue: nil) { _ in
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try KeybindingStore.setOverride(EditorCommandBinding(identifier: "duplicate-line",
                                                             keyEquivalent: "j",
                                                             modifierMask: [.command]))
        try KeybindingStore.resetToDefaults()

        wait(for: [changed], timeout: 2)
    }

    // MARK: - Menu application

    func testOverrideAppliesToMenuItems() throws {
        try KeybindingStore.setOverride(EditorCommandBinding(identifier: "duplicate-line",
                                                             keyEquivalent: "j",
                                                             modifierMask: [.command, .option]))

        let menu = try textMenu()
        let overridden = try XCTUnwrap(commandItem("duplicate-line", in: menu))
        XCTAssertEqual(overridden.keyEquivalent, "j")
        XCTAssertEqual(overridden.keyEquivalentModifierMask, [.command, .option])

        let untouched = try XCTUnwrap(commandItem("delete-line", in: menu))
        XCTAssertEqual(untouched.keyEquivalent, "d")
        XCTAssertEqual(untouched.keyEquivalentModifierMask, [.command, .shift])
    }

    func testKeybindingsSubmenuListsEveryCommandAndItsChord() throws {
        try KeybindingStore.setOverride(EditorCommandBinding(identifier: "duplicate-line",
                                                             keyEquivalent: "j",
                                                             modifierMask: [.command]))

        let menu = try textMenu()
        let submenu = try XCTUnwrap(menu.item(withTitle: "Keybindings")?.submenu)
        let rows = submenu.items.filter { ($0.representedObject as? String) != nil }
        XCTAssertEqual(rows.compactMap { $0.representedObject as? String },
                       CommandRegistry.default.commands.map(\.identifier))
        XCTAssertTrue(try XCTUnwrap(rows.first?.title).hasSuffix("⌘J"))
        XCTAssertTrue(submenu.items.contains { $0.title == "Reset to Defaults" })
    }

    func testResetToDefaultsRestoresMenuBindings() throws {
        try KeybindingStore.setOverride(EditorCommandBinding(identifier: "duplicate-line",
                                                             keyEquivalent: "j",
                                                             modifierMask: [.command]))
        var item = try XCTUnwrap(commandItem("duplicate-line", in: try textMenu()))
        XCTAssertEqual(item.keyEquivalent, "j")

        try KeybindingStore.resetToDefaults()

        XCTAssertFalse(FileManager.default.fileExists(atPath: KeybindingStore.overridesFileURL.path))
        item = try XCTUnwrap(commandItem("duplicate-line", in: try textMenu()))
        XCTAssertEqual(item.keyEquivalent, "d")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    }

    // MARK: - Malformed files

    func testMalformedOverrideFileDegradesToDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: KeybindingStore.overridesFileURL)

        XCTAssertTrue(KeybindingStore.loadOverrides().isEmpty)
        let item = try XCTUnwrap(commandItem("duplicate-line", in: try textMenu()))
        XCTAssertEqual(item.keyEquivalent, "d")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    }

    func testMalformedEntriesAreSkippedIndividually() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modifiers = NSEvent.ModifierFlags([.command, .option]).rawValue
        let json = """
        {
          "duplicate-line": { "keyEquivalent": "j", "modifiers": \(modifiers) },
          "delete-line": { "keyEquivalent": "", "modifiers": 1048576 },
          "move-line-up": "not an object",
          "move-line-down": { "keyEquivalent": "k" }
        }
        """
        try Data(json.utf8).write(to: KeybindingStore.overridesFileURL)

        let loaded = KeybindingStore.loadOverrides()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded["duplicate-line"]?.keyEquivalent, "j")

        let menu = try textMenu()
        let overridden = try XCTUnwrap(commandItem("duplicate-line", in: menu))
        XCTAssertEqual(overridden.keyEquivalent, "j")
        let skipped = try XCTUnwrap(commandItem("delete-line", in: menu))
        XCTAssertEqual(skipped.keyEquivalent, "d", "invalid entries fall back to defaults")
    }

    func testModifierlessOverrideIsRejected() throws {
        try KeybindingStore.setOverride(EditorCommandBinding(identifier: "duplicate-line",
                                                             keyEquivalent: "j",
                                                             modifierMask: []))

        // A bare "j" would intercept typing, so it never reaches the store.
        XCTAssertNil(KeybindingStore.loadOverrides()["duplicate-line"])
        let item = try XCTUnwrap(commandItem("duplicate-line", in: try textMenu()))
        XCTAssertEqual(item.keyEquivalent, "d")
    }

    // MARK: - Validation

    func testValidationStillWorksForOverriddenCommands() throws {
        try KeybindingStore.setOverride(EditorCommandBinding(identifier: "duplicate-line",
                                                             keyEquivalent: "j",
                                                             modifierMask: [.command]))
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "one\ntwo")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.validateMenuItem(validationItem("duplicate-line")))
        XCTAssertFalse(controller.validateMenuItem(validationItem("move-line-up")))

        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.validateMenuItem(validationItem("duplicate-line")))
    }

    // MARK: - Chord capture

    func testKeyChordFromEventNormalizesShiftAndRejectsPlainKeys() throws {
        let shifted = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
                                                     location: .zero,
                                                     modifierFlags: [.command, .shift],
                                                     timestamp: 0,
                                                     windowNumber: 0,
                                                     context: nil,
                                                     characters: "D",
                                                     charactersIgnoringModifiers: "D",
                                                     isARepeat: false,
                                                     keyCode: 2))
        let chord = try XCTUnwrap(KeybindingStore.keyChord(from: shifted))
        XCTAssertEqual(chord.keyEquivalent, "d")
        XCTAssertEqual(chord.modifierMask, [.command, .shift])

        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
                                                   location: .zero,
                                                   modifierFlags: [],
                                                   timestamp: 0,
                                                   windowNumber: 0,
                                                   context: nil,
                                                   characters: "j",
                                                   charactersIgnoringModifiers: "j",
                                                   isARepeat: false,
                                                   keyCode: 38))
        XCTAssertNil(KeybindingStore.keyChord(from: plain))
    }

    func testDisplayStringUsesMenuGlyphs() {
        let binding = EditorCommandBinding(identifier: "move-line-up",
                                           keyEquivalent: EditorCommandBinding.upArrow,
                                           modifierMask: [.command, .option])
        XCTAssertEqual(KeybindingStore.displayString(for: binding), "⌥⌘↑")
        XCTAssertEqual(KeybindingStore.displayString(for: nil), "None")
    }
}
