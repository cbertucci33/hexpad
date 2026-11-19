import XCTest
import AppKit
@testable import HexpadKit

/// Read-only enforcement at the DocumentModel mutation seam: every user-facing
/// text mutation is a no-op while the document is read-only, and the loader
/// seam (`reloadText(_:)`) stays exempt so external-change reloads keep
/// working. Typing itself is covered by the AppKit veto tests in
/// ReadOnlyMenuTests.
final class ReadOnlyProgrammaticTests: XCTestCase {

    private func readOnlyDoc(_ text: String = "abcdef") -> DocumentModel {
        let doc = DocumentModel(text: text)
        doc.setReadOnly(true)
        return doc
    }

    func testReplaceCharactersIsANoOpOnReadOnlyDocument() {
        let doc = readOnlyDoc()
        doc.replaceCharacters(in: NSRange(location: 0, length: 3), with: "XYZ")
        XCTAssertEqual(doc.text, "abcdef")
        XCTAssertFalse(doc.isModified)
    }

    func testReplaceAllTextIsANoOpOnReadOnlyDocument() {
        let doc = readOnlyDoc()
        doc.replaceAllText(with: "new text")
        XCTAssertEqual(doc.text, "abcdef")
        XCTAssertFalse(doc.isModified)
    }

    func testTextSetterIsANoOpOnReadOnlyDocument() {
        let doc = readOnlyDoc()
        doc.text = "new text"
        XCTAssertEqual(doc.text, "abcdef")
    }

    /// A rejected edit is a full no-op: nothing changes, nothing is posted,
    /// the dirty flag stays put.
    func testRejectedMutationsPostNoNotificationOrDirtyFlag() {
        let doc = readOnlyDoc()
        var notices = 0
        let token = NotificationCenter.default.addObserver(
            forName: DocumentModel.textDidChangeNotification,
            object: doc,
            queue: nil
        ) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        doc.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        doc.replaceAllText(with: "y")
        doc.text = "z"

        XCTAssertEqual(doc.text, "abcdef")
        XCTAssertEqual(notices, 0, "no notification storm for rejected edits")
        XCTAssertFalse(doc.isModified)
    }

    func testSetEncodingIsANoOpOnReadOnlyDocument() {
        let doc = readOnlyDoc()
        doc.setEncoding("UTF-16LE")
        XCTAssertEqual(doc.encoding, "UTF-8")
    }

    func testConvertEOLIsANoOpOnReadOnlyDocument() {
        let doc = readOnlyDoc()
        let before = doc.eolType
        doc.convertEOL(to: "CRLF")
        XCTAssertEqual(doc.eolType, before)
        XCTAssertFalse(doc.hasPendingSaveConversion)
    }

    func testConvertEncodingIsANoOpOnReadOnlyDocument() {
        let doc = readOnlyDoc()
        XCTAssertNoThrow(try doc.convertEncoding(to: "UTF-16LE"))
        XCTAssertEqual(doc.saveEncoding, doc.encoding)
    }

    func testRedecodeIsANoOpOnReadOnlyDocument() {
        let doc = readOnlyDoc()
        let result = doc.redecode(from: Data("decoded".utf8), as: "UTF-8")
        XCTAssertFalse(result)
        XCTAssertEqual(doc.text, "abcdef")
    }

    /// The loader seam bypasses the lock by design: external-change reloads
    /// and session restores must keep working on a read-only buffer.
    func testReloadTextBypassesTheReadOnlyLock() {
        let doc = readOnlyDoc()
        doc.reloadText("new text")
        XCTAssertEqual(doc.text, "new text")
        XCTAssertFalse(doc.isModified, "a reload makes the loaded text the clean baseline")
    }

    func testMutationsWorkAgainAfterUnlocking() {
        let doc = readOnlyDoc()
        doc.setReadOnly(false)
        doc.replaceCharacters(in: NSRange(location: 0, length: 3), with: "XYZ")
        XCTAssertEqual(doc.text, "XYZdef")
    }

    /// Control: the guard is about the lock, not about broken mutation paths —
    /// a writable document accepts the same mutations.
    func testWritableDocumentStillMutates() {
        let doc = DocumentModel(text: "abcdef")
        doc.replaceCharacters(in: NSRange(location: 0, length: 3), with: "XYZ")
        XCTAssertEqual(doc.text, "XYZdef")
    }
}
