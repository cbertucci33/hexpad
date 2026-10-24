import XCTest
@testable import HexpadKit
import Foundation

final class SessionStoreTests: XCTestCase {
    var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HexpadSessionTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        // Isolate from CB's real session file in Application Support.
        SessionStore.overrideDirectory = testDir
    }

    override func tearDown() {
        SessionStore.overrideDirectory = nil
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    func testNoSessionFileReturnsNil() {
        // Fresh temp dir: no session.json exists anywhere SessionStore looks.
        let result = SessionStore.restore()
        XCTAssertNil(result)
    }

    func testSaveAndRestore() throws {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "one"))
        store.addDocument(DocumentModel(text: "two"))
        store.selectDocument(at: 1)

        try SessionStore.save(store)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: testDir.appendingPathComponent("session.json").path))

        let restored = SessionStore.restore()
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.selectedIndex, 1)
        XCTAssertEqual(restored?.tabs.documents.count, 2)
        XCTAssertEqual(restored?.tabs.documents[0].text, "one")
        XCTAssertEqual(restored?.tabs.documents[1].text, "two")
    }

    func testSavePreservesRecentsWrittenSeparately() throws {
        // Regression: save() used to wipe "recents" written by saveRecents().
        let store = TabStore()
        store.addDocument(DocumentModel(text: "only"))
        try SessionStore.save(store)
        try SessionStore.saveRecents(["/tmp/a.hex", "/tmp/b.hex"])
        try SessionStore.save(store)

        XCTAssertEqual(SessionStore.loadRecents(), ["/tmp/a.hex", "/tmp/b.hex"])
        XCTAssertNotNil(SessionStore.restore())
    }

    func testClear() throws {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "x"))
        try SessionStore.save(store)
        XCTAssertNotNil(SessionStore.restore())
        try SessionStore.clear()
        XCTAssertNil(SessionStore.restore())
    }
}
