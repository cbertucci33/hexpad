import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// V19k-2: the close button follows the Tab Bar > "Close button: active + hover
/// only" preference. The default keeps every × visible; the opt-in mode shows
/// it on the selected tab and on a hovered tab only.
final class CloseButtonPreferenceTests: XCTestCase {

    private func makeBar(tabCount: Int,
                         visibility: CloseButtonVisibility = .always) -> (TabBarView, TabStore) {
        let store = TabStore()
        for i in 0..<tabCount {
            store.addDocument(DocumentModel(text: "doc \(i)"))
        }
        store.selectedIndex = 0
        let bar = TabBarView(tabStore: store)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
        bar.closeButtonVisibility = visibility
        bar.reloadTabs()
        return (bar, store)
    }

    private func tabButtons(in bar: TabBarView) -> [TabButton] {
        bar.subviews.compactMap { $0 as? TabButton }
    }

    /// `NSEvent.mouseEvent` rejects `.mouseEntered`/`.mouseExited`; a mouse-moved
    /// event is a valid carrier because the hover handlers only change state.
    private func mouseEvent(type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: .zero,
                           modifierFlags: [],
                           timestamp: 0,
                           windowNumber: 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: 1,
                           pressure: 0)!
    }

    private func findCheckbox(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let found = findCheckbox(titled: title, in: subview) { return found }
        }
        return nil
    }

    // MARK: - Visibility behaviour

    func testAlwaysDefaultShowsCloseButtonOnSelectedAndUnselectedTabs() {
        let (bar, _) = makeBar(tabCount: 3)
        let buttons = tabButtons(in: bar)
        XCTAssertEqual(buttons.count, 3)

        XCTAssertEqual(Preferences.defaults.closeButtonVisibility, .always,
                       "existing users keep the historical behaviour")
        for button in buttons {
            XCTAssertFalse(button.closeButton?.isHidden ?? true,
                           "tab \(button.index) keeps its × in the default mode")
        }
    }

    func testActiveAndHoverShowsCloseOnlyOnSelectedAndHoveredTabs() {
        let (bar, store) = makeBar(tabCount: 3, visibility: .activeAndHover)
        let buttons = tabButtons(in: bar)
        let selected = buttons[store.selectedIndex]
        let unselected = buttons.first { $0.index != store.selectedIndex }!

        XCTAssertFalse(selected.closeButton?.isHidden ?? true,
                       "the selected tab always shows its ×")
        XCTAssertTrue(unselected.closeButton?.isHidden ?? false,
                      "an unselected, unhovered tab hides its ×")

        unselected.mouseEntered(with: mouseEvent(type: .mouseMoved))
        XCTAssertFalse(unselected.closeButton?.isHidden ?? true,
                       "hovering an unselected tab reveals its ×")
        XCTAssertFalse(selected.closeButton?.isHidden ?? true,
                       "hovering a neighbour leaves the selected tab's × visible")

        unselected.mouseExited(with: mouseEvent(type: .mouseMoved))
        XCTAssertTrue(unselected.closeButton?.isHidden ?? false,
                      "leaving the tab hides its × again")

        // Selection changes also drive the visibility with no hover involved.
        store.selectedIndex = unselected.index
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"),
                                        object: nil)
        XCTAssertFalse(unselected.closeButton?.isHidden ?? true,
                       "selecting the previously hovered tab keeps its × shown")
        XCTAssertTrue(selected.closeButton?.isHidden ?? false,
                      "the old selected tab hides its × once deselected")
    }

    // MARK: - Preference round trip

    func testCloseButtonVisibilityRawValuesAreStable() {
        XCTAssertEqual(CloseButtonVisibility.always.rawValue, "always")
        XCTAssertEqual(CloseButtonVisibility.activeAndHover.rawValue, "activeAndHover")
    }

    func testEncodeDecodePreservesCloseButtonVisibility() throws {
        var preferences = Preferences.defaults
        preferences.closeButtonVisibility = .activeAndHover

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.closeButtonVisibility, .activeAndHover)
        XCTAssertEqual(decoded, preferences)
    }

    func testMissingOrUnknownCloseButtonVisibilityKeyFallsBackToAlways() throws {
        let missing = try JSONDecoder().decode(Preferences.self,
                                               from: Data(#"{"fontSize": 15}"#.utf8))
        XCTAssertEqual(missing.closeButtonVisibility, .always)

        let unknown = try JSONDecoder().decode(
            Preferences.self,
            from: Data(#"{"closeButtonVisibility": "whenever"}"#.utf8))
        XCTAssertEqual(unknown.closeButtonVisibility, .always,
                       "an unrecognized raw value degrades to the default")
    }

    // MARK: - Preferences pane

    func testPaneCheckboxMapsToActiveAndHover() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-close-button-tests-\(UUID().uuidString)")
        PreferencesStore.overrideDirectory = directory
        defer {
            PreferencesStore.overrideDirectory = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let controller = PreferencesWindowController()
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let checkbox = try XCTUnwrap(
            findCheckbox(titled: "Close button: active + hover only", in: content))

        checkbox.state = .off
        if let action = checkbox.action { _ = checkbox.target?.perform(action, with: checkbox) }
        XCTAssertEqual(PreferencesStore.load().closeButtonVisibility, .always)

        checkbox.state = .on
        if let action = checkbox.action { _ = checkbox.target?.perform(action, with: checkbox) }
        XCTAssertEqual(PreferencesStore.load().closeButtonVisibility, .activeAndHover)
    }
}
