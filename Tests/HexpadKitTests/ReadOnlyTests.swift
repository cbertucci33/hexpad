import XCTest
import AppKit
@testable import HexpadKit

/// P16d-3: Edit > Read-Only's per-document flag.
///
/// The model owns the flag (the same place it owns language/encoding/fold
/// state) and publishes a dedicated notice when it changes. Dirty state is
/// deliberately independent: locking a buffer must not silently clean it.
final class ReadOnlyTests: XCTestCase {

    func testDocumentStartsWritable() {
        XCTAssertFalse(DocumentModel(text: "hello").isReadOnly)
    }

    /// Mirrors `DocumentModel.textDidChangeNotification`: observers get the
    /// document itself as the notification object.
    func testSetReadOnlyPostsReadOnlyDidChangeNotification() {
        let doc = DocumentModel(text: "hello")
        let expectation = expectation(description: "read-only change posted")
        var observed: DocumentModel?
        let token = NotificationCenter.default.addObserver(
            forName: DocumentModel.readOnlyDidChangeNotification,
            object: doc,
            queue: nil
        ) { note in
            observed = note.object as? DocumentModel
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        doc.setReadOnly(true)

        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(doc.isReadOnly)
        XCTAssertTrue(observed === doc)
    }

    /// Both directions publish, so a single observer (e.g. the menu checkmark
    /// refresh) never has to guess which way the toggle went.
    func testLockingAndUnlockingBothPostNotifications() {
        let doc = DocumentModel(text: "hello")
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: DocumentModel.readOnlyDidChangeNotification,
            object: doc,
            queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        doc.setReadOnly(true)
        XCTAssertTrue(doc.isReadOnly)
        doc.setReadOnly(false)
        XCTAssertFalse(doc.isReadOnly)
        XCTAssertEqual(count, 2)
    }

    /// The flag survives a session round-trip because `toSessionData` writes
    /// every key individually and `fromSessionData` decodes each with a
    /// fallback, exactly like word wrap / BOM / tab colour.
    func testReadOnlyRoundTripsThroughSessionData() {
        let doc = DocumentModel(text: "alpha")
        doc.setReadOnly(true)

        let data = doc.toSessionData()
        XCTAssertEqual(data["isReadOnly"] as? Bool, true)

        let restored = DocumentModel.fromSessionData(data)
        XCTAssertNotNil(restored)
        XCTAssertTrue(restored?.isReadOnly == true)

        doc.setReadOnly(false)
        XCTAssertEqual(DocumentModel.fromSessionData(doc.toSessionData())?.isReadOnly, false)
    }

    /// Sessions written before this slice lack the key entirely. They must
    /// restore writable, never read-only.
    func testLegacySessionWithoutReadOnlyKeyRestoresWritable() {
        var legacy = DocumentModel(text: "old").toSessionData()
        legacy.removeValue(forKey: "isReadOnly")
        XCTAssertFalse(DocumentModel.fromSessionData(legacy)?.isReadOnly == true)

        legacy["isReadOnly"] = "not a bool"
        XCTAssertFalse(DocumentModel.fromSessionData(legacy)?.isReadOnly == true)
    }

    /// Locking is a view policy, not a content edit: a clean buffer stays clean
    /// and a dirty buffer stays dirty. `setReadOnly` must never post the dirty
    /// flag's general-purpose notification either. While locked, mutations are
    /// rejected at the model seam, so the text and the dirty flag stay put.
    func testReadOnlyLeavesDirtyStateUntouched() {
        let doc = DocumentModel(text: "draft")
        doc.setModified(false)
        XCTAssertFalse(doc.isModified)

        var dirtyNotices = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DocumentModifiedDidChange"),
            object: nil,
            queue: nil
        ) { _ in dirtyNotices += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        doc.setReadOnly(true)
        XCTAssertFalse(doc.isModified, "locking a saved buffer must not imply unsaved edits")
        XCTAssertEqual(dirtyNotices, 0)

        doc.replaceCharacters(in: NSRange(location: 0, length: 5), with: "revised")
        XCTAssertEqual(doc.text, "draft", "a read-only buffer rejects mutations")
        XCTAssertFalse(doc.isModified, "a rejected mutation leaves the dirty flag alone")
        XCTAssertEqual(dirtyNotices, 0)

        doc.setReadOnly(false)
        XCTAssertFalse(doc.isModified)
        doc.replaceCharacters(in: NSRange(location: 0, length: 5), with: "revised")
        XCTAssertTrue(doc.isModified, "a writable buffer accepts the mutation")
    }
}
