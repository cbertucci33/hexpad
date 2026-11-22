import XCTest
import AppKit
@testable import Hexpad
@testable import HexpadKit

/// Card 9387adde — reverting to a saved snapshot restores older text without
/// writing it to disk, so the document must remain dirty. Otherwise Close/quit
/// skip the save prompt and session restore silently loses the reverted state.
final class ChangeHistoryRevertDirtyTests: XCTestCase {

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        return controller
    }

    func testRevertLeavesDocumentDirty() throws {
        let controller = makeController()
        let doc = DocumentModel(text: "original")
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0

        // Save point holds "original"; the live buffer moves on to new text.
        controller.recordSavePoint(for: doc)
        doc.text = "heavily edited"

        let history = controller.history(for: doc)
        let saved = try XCTUnwrap(history.menuEntries.first { $0.title.hasPrefix("Saved on") })
        let item = NSMenuItem(title: saved.title,
                              action: #selector(MainWindowController.revertToHistoryEntry(_:)),
                              keyEquivalent: "")
        item.representedObject = saved

        controller.revertToHistoryEntry(item)

        XCTAssertEqual(doc.text, "original", "revert restores the exact snapshot")
        XCTAssertTrue(doc.isModified,
                      "revert must leave the doc dirty — the older text was never written to disk, "
                        + "so Close/quit must still prompt and the session must persist modified state")
    }
}

/// Card e9bca429 — the since-save edit log must be fed by the same real-text
/// seam that drives the menu, and a save point must clear it.
final class ChangeHistorySinceSaveWiringTests: XCTestCase {

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        return controller
    }

    func testTextChangeAdvancesSinceSaveCountAndSavePointClearsIt() {
        let controller = makeController()
        let doc = DocumentModel(text: "original")
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0

        doc.text = "edited"

        let history = controller.history(for: doc)
        XCTAssertEqual(history.changesSinceSaveCount, 1,
                       "a real text change is recorded at the controller seam")
        XCTAssertTrue(history.hasChangesSinceSave)
        XCTAssertTrue(doc.unsavedChanges)

        controller.recordSavePoint(for: doc)
        doc.setModified(false)

        XCTAssertEqual(history.changesSinceSaveCount, 0, "a save point clears the since-save log")
        XCTAssertFalse(history.hasChangesSinceSave)
        XCTAssertFalse(doc.unsavedChanges)
    }

    /// P-19 (1): the typing seam republishes the model notice with the edit
    /// range in `userInfo["editedRange"]` (an NSValue). The controller extracts
    /// that exact key when it records the since-save edit. Posting the notice
    /// the way `textDidChange` does pins the key contract: if the key were
    /// renamed, the count would still tick but the recorded range would be nil.
    func testTypedEditNotificationCarriesItsRangeIntoTheSinceSaveLog() {
        let controller = makeController()
        let doc = DocumentModel(text: "original")
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0
        let edited = NSRange(location: 3, length: 2)

        NotificationCenter.default.post(
            name: DocumentModel.textDidChangeNotification,
            object: doc,
            userInfo: ["editedRange": NSValue(range: edited)]
        )

        let history = controller.history(for: doc)
        XCTAssertEqual(history.changesSinceSaveCount, 1)
        XCTAssertEqual(history.editsSinceSave.last?.range, edited,
                       "the userInfo key must be the one the controller reads")
    }

    /// P-19 (2): the real File > Save path (not a direct `recordSavePoint`
    /// call) must write the buffer and clear the since-save log through
    /// `saveFile()`. Removing the `recordSavePoint` call from `saveFile` makes
    /// the count stay at 1.
    func testSaveFileClearsTheSinceSaveLogThroughTheRealSavePath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-save-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("save-flow.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let controller = makeController()
        let doc = DocumentModel(text: "original", filePath: file)
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0

        doc.text = "edited"
        let history = controller.history(for: doc)
        XCTAssertEqual(history.changesSinceSaveCount, 1)

        controller.saveFile()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "edited")
        XCTAssertEqual(history.changesSinceSaveCount, 0,
                       "the real save flow records the save point")
        XCTAssertFalse(history.hasChangesSinceSave)
        XCTAssertFalse(doc.unsavedChanges)
        XCTAssertTrue(history.menuEntries.contains { $0.isSaved && $0.snapshot == "edited" },
                      "the save point snapshots the text that reached disk")
    }
}
