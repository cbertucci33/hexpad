import XCTest
@testable import HexpadKit
import Foundation

final class SessionAtomicWriteTests: XCTestCase {
    private var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HexpadAtomicSessionTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        SessionStore.overrideDirectory = testDir
        SessionStore.debounceInterval = 2.0
        SessionStore.beforeCommit = nil
    }

    override func tearDown() {
        SessionStore.cancelScheduledSave()
        SessionStore.beforeCommit = nil
        SessionStore.overrideDirectory = nil
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private var sessionURL: URL {
        testDir.appendingPathComponent("session.json")
    }

    private func makeStore(_ texts: [String], selectedIndex: Int = 0) -> TabStore {
        let store = TabStore()
        for text in texts {
            store.addDocument(DocumentModel(text: text))
        }
        store.selectDocument(at: selectedIndex)
        return store
    }

    private func sessionDictionary() throws -> [String: Any] {
        let data = try Data(contentsOf: sessionURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Anything other than the live session file would be a leaked temp file.
    private func extraFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: testDir.path)) ?? []
        return names.filter { $0 != "session.json" }
    }

    private func wait(_ interval: TimeInterval) {
        let exp = expectation(description: "wait \(interval)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { exp.fulfill() }
        wait(for: [exp], timeout: interval + 2)
    }

    // MARK: - Tests

    func testSaveWritesAValidSessionFile() throws {
        let store = makeStore(["one", "two"], selectedIndex: 1)
        try SessionStore.save(store)

        let dict = try sessionDictionary()
        XCTAssertEqual(dict["selectedIndex"] as? Int, 1)
        XCTAssertEqual((dict["tabs"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(extraFiles(), [], "atomic write must not leave temp files behind")

        let restored = try XCTUnwrap(SessionStore.restore())
        XCTAssertEqual(restored.selectedIndex, 1)
        XCTAssertEqual(restored.tabs.documents.map(\.text), ["one", "two"])
    }

    func testRepeatedSavesLeaveNoTemporaryFiles() throws {
        let store = makeStore(["v0"])

        for index in 0..<5 {
            store.documents[0].text = "v\(index)"
            try SessionStore.save(store)
        }

        XCTAssertEqual(extraFiles(), [])
        let restored = try XCTUnwrap(SessionStore.restore())
        XCTAssertEqual(restored.tabs.documents.first?.text, "v4")
    }

    func testDirtyChangesCoalesceIntoOneWrite() throws {
        SessionStore.debounceInterval = 0.15
        let lock = NSLock()
        var commits = 0
        SessionStore.beforeCommit = {
            lock.lock()
            commits += 1
            lock.unlock()
        }

        let store = makeStore(["start"])
        for index in 0..<6 {
            store.documents[0].text = "edit-\(index)"
            SessionStore.scheduleSave(store)
        }

        XCTAssertTrue(SessionStore.hasPendingChanges)

        wait(0.7)

        lock.lock()
        let commitCount = commits
        lock.unlock()

        XCTAssertEqual(commitCount, 1, "rapid changes should coalesce into one write")
        XCTAssertFalse(SessionStore.hasPendingChanges)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))
        let restored = try XCTUnwrap(SessionStore.restore())
        XCTAssertEqual(restored.tabs.documents.first?.text, "edit-5",
                       "the coalesced write should persist the newest state")
    }

    func testScheduledWritePersistsLatestState() throws {
        SessionStore.debounceInterval = 0.1
        let store = makeStore(["before"])
        SessionStore.scheduleSave(store)

        // A later mutation before the timer fires must be what lands on disk.
        store.documents[0].text = "after"
        wait(0.4)

        XCTAssertEqual(SessionStore.restore()?.tabs.documents.first?.text, "after")
        XCTAssertFalse(SessionStore.hasPendingChanges)
    }

    func testFlushWritesPendingChangesImmediately() throws {
        SessionStore.debounceInterval = 5.0
        let lock = NSLock()
        var commits = 0
        SessionStore.beforeCommit = {
            lock.lock()
            commits += 1
            lock.unlock()
        }

        let store = makeStore(["flushed"])
        SessionStore.scheduleSave(store)
        XCTAssertTrue(SessionStore.hasPendingChanges)

        try SessionStore.flush()

        XCTAssertFalse(SessionStore.hasPendingChanges)
        XCTAssertEqual(SessionStore.restore()?.tabs.documents.first?.text, "flushed")

        // The cancelled timer must not fire later and produce a second write.
        wait(0.3)

        lock.lock()
        let commitCount = commits
        lock.unlock()
        XCTAssertEqual(commitCount, 1)
    }

    func testExplicitSaveSupersedesScheduledWrite() throws {
        SessionStore.debounceInterval = 5.0
        let lock = NSLock()
        var commits = 0
        SessionStore.beforeCommit = {
            lock.lock()
            commits += 1
            lock.unlock()
        }

        let store = makeStore(["scheduled"])
        SessionStore.scheduleSave(store)
        store.documents[0].text = "explicit"

        try SessionStore.save(store)

        XCTAssertFalse(SessionStore.hasPendingChanges)
        XCTAssertEqual(SessionStore.restore()?.tabs.documents.first?.text, "explicit")

        wait(0.3)

        lock.lock()
        let commitCount = commits
        lock.unlock()
        XCTAssertEqual(commitCount, 1, "the superseded timer must not write again")
    }

    func testFailedWriteLeavesPreviousFileIntactAndNoPartialFile() throws {
        let original = makeStore(["original"])
        try SessionStore.save(original)
        let originalData = try Data(contentsOf: sessionURL)

        SessionStore.beforeCommit = {
            throw NSError(domain: "SessionAtomicWriteTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "simulated failure"])
        }

        let replacement = makeStore(["replacement"])
        XCTAssertThrowsError(try SessionStore.save(replacement))

        XCTAssertEqual(try Data(contentsOf: sessionURL), originalData,
                       "a failed write must not damage the previous session file")
        XCTAssertEqual(extraFiles(), [], "a failed write must clean up its temp file")
        XCTAssertEqual(SessionStore.restore()?.tabs.documents.first?.text, "original")
    }

    func testFailedScheduledFlushStaysDirtyAndRetriesCleanly() throws {
        SessionStore.debounceInterval = 0.1
        let original = makeStore(["original"])
        try SessionStore.save(original)
        let originalData = try Data(contentsOf: sessionURL)

        SessionStore.beforeCommit = {
            throw NSError(domain: "SessionAtomicWriteTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "simulated failure"])
        }

        let updated = makeStore(["updated"])
        SessionStore.scheduleSave(updated)
        wait(0.4)

        XCTAssertTrue(SessionStore.hasPendingChanges, "a failed flush must stay dirty for retry")
        XCTAssertNotNil(SessionStore.lastWriteError)
        XCTAssertEqual(try Data(contentsOf: sessionURL), originalData)
        XCTAssertEqual(extraFiles(), [])

        SessionStore.beforeCommit = nil
        try SessionStore.flush()

        XCTAssertFalse(SessionStore.hasPendingChanges)
        XCTAssertNil(SessionStore.lastWriteError)
        XCTAssertEqual(SessionStore.restore()?.tabs.documents.first?.text, "updated")
    }

    func testConcurrentSavesDoNotOverlap() throws {
        let lock = NSLock()
        var activeWrites = 0
        var peakWrites = 0

        SessionStore.beforeCommit = {
            lock.lock()
            activeWrites += 1
            peakWrites = max(peakWrites, activeWrites)
            lock.unlock()

            Thread.sleep(forTimeInterval: 0.01)

            lock.lock()
            activeWrites -= 1
            lock.unlock()
        }

        let store = makeStore(["concurrent"])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            try? SessionStore.save(store)
        }

        lock.lock()
        let peak = peakWrites
        lock.unlock()

        XCTAssertEqual(peak, 1, "writes must be serialized, never overlapping")
        XCTAssertEqual(extraFiles(), [])
        XCTAssertEqual(SessionStore.restore()?.tabs.documents.first?.text, "concurrent")
    }
}
