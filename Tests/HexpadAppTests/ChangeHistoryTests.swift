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
