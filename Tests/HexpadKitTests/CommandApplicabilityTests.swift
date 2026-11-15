import XCTest
@testable import HexpadKit

/// Menu validation asks one question of the registry: would this command change
/// the buffer? These tests pin that contract down for every default command, so
/// the app layer can disable no-op menu items without reimplementing the line
/// logic. Command *output* is covered in CommandRegistryTests; this file only
/// covers the changed/unchanged predicate.
final class CommandApplicabilityTests: XCTestCase {

    private func changes(_ identifier: String,
                         text: String,
                         selection: NSRange) -> Bool? {
        guard let result = CommandRegistry.default.execute(identifier,
                                                           text: text,
                                                           selection: selection) else {
            return nil
        }
        return result.text != text
    }

    func testNoOpCasesLeaveTextUnchanged() {
        // Moving the first line up and the last line down are the N++ no-ops
        // that must grey out in the Text menu.
        XCTAssertEqual(changes("move-line-up", text: "a\nb", selection: NSRange(location: 0, length: 0)), false)
        XCTAssertEqual(changes("move-line-down", text: "a\nb", selection: NSRange(location: 2, length: 0)), false)
        // Case commands require a non-empty selection.
        XCTAssertEqual(changes("uppercase", text: "abc", selection: NSRange(location: 1, length: 0)), false)
        XCTAssertEqual(changes("lowercase", text: "ABC", selection: NSRange(location: 1, length: 0)), false)
        // Nothing to comment or delete in a blank/empty buffer.
        XCTAssertEqual(changes("toggle-line-comment", text: "  \n\t", selection: NSRange(location: 0, length: 4)), false)
        XCTAssertEqual(changes("delete-line", text: "", selection: NSRange(location: 0, length: 0)), false)
    }

    func testApplicableCasesChangeText() {
        XCTAssertEqual(changes("duplicate-line", text: "", selection: NSRange(location: 0, length: 0)), true)
        XCTAssertEqual(changes("delete-line", text: "a\nb", selection: NSRange(location: 0, length: 0)), true)
        XCTAssertEqual(changes("move-line-up", text: "a\nb", selection: NSRange(location: 2, length: 0)), true)
        XCTAssertEqual(changes("move-line-down", text: "a\nb", selection: NSRange(location: 0, length: 0)), true)
        XCTAssertEqual(changes("toggle-line-comment", text: "a", selection: NSRange(location: 0, length: 0)), true)
        XCTAssertEqual(changes("uppercase", text: "abc", selection: NSRange(location: 0, length: 3)), true)
        XCTAssertEqual(changes("lowercase", text: "ABC", selection: NSRange(location: 0, length: 3)), true)
    }

    func testCaseTransformOfAlreadyCasedSelectionIsInapplicable() {
        XCTAssertEqual(changes("uppercase", text: "ABC", selection: NSRange(location: 0, length: 3)), false)
        XCTAssertEqual(changes("lowercase", text: "abc", selection: NSRange(location: 0, length: 3)), false)
    }

    func testUnknownIdentifierIsNotApplicable() {
        XCTAssertNil(changes("not-a-command", text: "abc", selection: NSRange(location: 0, length: 0)))
    }

    func testOutOfBoundsSelectionClampsToAnApplicableEdit() {
        // The app passes the text view's selection straight through, so the
        // registry must clamp rather than fail or drift outside the buffer.
        XCTAssertEqual(changes("duplicate-line", text: "a", selection: NSRange(location: 99, length: 5)), true)
        XCTAssertEqual(changes("uppercase", text: "abc", selection: NSRange(location: 99, length: 5)), false)
    }
}
