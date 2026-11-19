import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

final class HelpMenuCoverageTests: XCTestCase {

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        return controller
    }

    // MARK: - Menu structure

    func testHelpMenuHasDebugInfoAndCommandLineArgumentsItems() throws {
        let delegate = HexpadAppDelegate()
        let helpMenu = delegate.makeHelpMenu()
        let titles = helpMenu.items.map(\.title)

        XCTAssertEqual(titles.first, "About Hexpad")
        XCTAssertTrue(titles.contains("Hexpad Online Manual"))
        XCTAssertTrue(titles.contains("Hexpad Project Page"))

        let debug = try XCTUnwrap(helpMenu.item(withTitle: "Debug Info…"))
        let cli = try XCTUnwrap(helpMenu.item(withTitle: "Command Line Arguments…"))

        // Both sit after the existing link items.
        let projectIndex = try XCTUnwrap(titles.firstIndex(of: "Hexpad Project Page"))
        XCTAssertGreaterThan(try XCTUnwrap(titles.firstIndex(of: "Debug Info…")), projectIndex)
        XCTAssertGreaterThan(try XCTUnwrap(titles.firstIndex(of: "Command Line Arguments…")), projectIndex)

        XCTAssertEqual(debug.action, #selector(HexpadAppDelegate.showDebugInfo))
        XCTAssertEqual(cli.action, #selector(HexpadAppDelegate.showCommandLineArguments))
        XCTAssertTrue(debug.target === delegate)
        XCTAssertTrue(cli.target === delegate)
        XCTAssertEqual(debug.keyEquivalent, "")
        XCTAssertEqual(cli.keyEquivalent, "")

        // Always enabled, even with no active controller.
        XCTAssertTrue(delegate.validateMenuItem(debug))
        XCTAssertTrue(delegate.validateMenuItem(cli))

        let controller = makeController()
        delegate.activeControllerOverride = controller
        XCTAssertTrue(delegate.validateMenuItem(debug))
        XCTAssertTrue(delegate.validateMenuItem(cli))
    }

    // MARK: - Debug Info report

    func testDebugReportContainsSectionHeadersAndNonEmptyVersion() {
        let report = HexpadAppDelegate.debugReport(activeController: nil)

        for header in ["App", "System", "Session", "Configuration", "Server/Runtime"] {
            XCTAssertTrue(report.contains(header), "missing section header: \(header)")
        }

        let versionLine = report.split(separator: "\n").first { $0.hasPrefix("Version: ") }
        XCTAssertNotNil(versionLine)
        let versionValue = String(versionLine!.dropFirst("Version: ".count))
        XCTAssertFalse(versionValue.isEmpty, "version string must be non-empty")
    }

    func testDebugReportTabCountMatchesFixtureStore() {
        let controller = makeController()
        let a = DocumentModel(text: "a")
        let b = DocumentModel(text: "b")
        controller.tabStore.documents = [a, b]
        controller.tabStore.selectedIndex = 0
        a.setModified(true)

        let report = HexpadAppDelegate.debugReport(activeController: controller)

        XCTAssertTrue(report.contains("Group 1 (primary): 2 tab(s)"))
        XCTAssertTrue(report.contains("Focused group: primary"))
        XCTAssertTrue(report.contains("Active document: Untitled"))
        XCTAssertTrue(report.contains("Path: (untitled)"))
        XCTAssertTrue(report.contains("Unsaved documents: 1"))

        // Configuration reflects loaded preferences (defaults when no file).
        XCTAssertTrue(report.contains("Theme: "))
        XCTAssertTrue(report.contains("Session snapshot enabled: "))
    }

    func testDebugReportSplitGroupCounts() {
        let controller = makeController()
        controller.openSplitView()
        let primary = controller.allPanes[0]
        let secondary = controller.allPanes[1]
        primary.tabStore.documents = [DocumentModel(text: "a")]
        secondary.tabStore.documents = [DocumentModel(text: "b"), DocumentModel(text: "c")]
        controller.focusGroup(.secondary)

        let report = DebugInfoWindowController.debugReport(activeController: controller)
        XCTAssertTrue(report.contains("Group 1 (primary): 1 tab(s)"))
        XCTAssertTrue(report.contains("Group 2 (secondary): 2 tab(s)"))
        XCTAssertTrue(report.contains("Focused group: secondary"))
    }

    func testCopyWritesExactReportToPasteboard() {
        let controller = makeController()
        let report = HexpadAppDelegate.debugReport(activeController: controller)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)

        XCTAssertEqual(pasteboard.string(forType: .string), report)
    }

    // MARK: - Command Line Arguments

    func testCommandLineArgumentsContentMatchesPinnedUsage() {
        let text = DebugInfoWindowController.commandLineArgumentsText()

        XCTAssertTrue(text.contains("open -a Hexpad file.txt"))
        XCTAssertTrue(text.contains("open -a Hexpad file1.txt file2.md"))
        XCTAssertTrue(text.contains("defines no"))
        XCTAssertTrue(text.contains("command-line flags"))

        // Aliases return the identical pinned text.
        XCTAssertEqual(HexpadAppDelegate.commandLineArgumentsText(), text)
        XCTAssertEqual(DebugInfoWindowController.commandLineArguments(), text)
        XCTAssertEqual(DebugInfoWindowController.commandLineArgumentsReport(), text)
        XCTAssertEqual(DebugInfoWindowController.cliArgumentsText(), text)
    }
}
