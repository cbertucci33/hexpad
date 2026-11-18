import XCTest
@testable import HexpadKit
import Foundation

/// P16d-2: explicit session files (File > Save Session… / Load Session…).
///
/// The public seam is `SessionStore.Snapshot` plus `saveSnapshot`/`loadSnapshot`.
/// An explicit file must use the very same JSON Snapshot format as the
/// auto-save `session.json`, so a saved session is byte-compatible with the
/// workspace file and can be loaded back through `TabStore.fromSessionData`.
final class SessionFilesTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-session-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SessionStore.overrideDirectory = directory
        SessionStore.cancelScheduledSave()
    }

    override func tearDownWithError() throws {
        SessionStore.cancelScheduledSave()
        SessionStore.overrideDirectory = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeFile(named name: String, text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSnapshotRoundTripsThroughAnExplicitSessionFile() throws {
        let firstURL = try makeFile(named: "alpha.txt", text: "alpha\n")
        let thirdURL = try makeFile(named: "gamma.txt", text: "gamma\n")

        let store = TabStore()
        let alpha = DocumentModel(text: "alpha\n", filePath: firstURL)
        let untitled = DocumentModel(text: "draft buffer")
        let gamma = DocumentModel(text: "gamma\n", filePath: thirdURL)
        store.addDocument(alpha)
        store.addDocument(untitled)
        store.addDocument(gamma)
        store.selectedIndex = 1 // mixed: neither first nor last

        let sessionURL = directory.appendingPathComponent("Untitled.session")
        try SessionStore.saveSnapshot(SessionStore.Snapshot.make(from: store), to: sessionURL)

        let loaded = try SessionStore.loadSnapshot(from: sessionURL)
        XCTAssertEqual(loaded.tabs.count, 3)
        XCTAssertEqual(loaded.selectedIndex, 1, "the selected index lives in the Snapshot")

        let restored = TabStore.fromSessionData(loaded.tabs)
        // fromSessionData selects the last inserted tab; the caller (like the
        // startup restore path) applies the Snapshot's selection afterwards.
        restored.selectedIndex = min(loaded.selectedIndex, max(0, restored.count - 1))
        XCTAssertEqual(restored.documents.count, 3, "all three tabs survive")
        XCTAssertEqual(restored.selectedIndex, 1)

        XCTAssertEqual(restored.documents[0].name, alpha.name)
        XCTAssertEqual(restored.documents[0].filePath?.path, firstURL.path)
        XCTAssertEqual(restored.documents[0].text, "alpha\n")

        XCTAssertEqual(restored.documents[1].name, untitled.name)
        XCTAssertTrue(restored.documents[1].isUntitled, "the untitled tab stays untitled")
        XCTAssertNil(restored.documents[1].filePath)
        XCTAssertEqual(restored.documents[1].text, "draft buffer")

        XCTAssertEqual(restored.documents[2].name, gamma.name)
        XCTAssertEqual(restored.documents[2].filePath?.path, thirdURL.path)
        XCTAssertEqual(restored.documents[2].text, "gamma\n")
    }

    /// Both the explicit file and the auto-save workspace file go through the
    /// one encoder, so their JSON shape is identical (aside from extra keys
    /// such as "recents" that the workspace file may carry).
    func testExplicitFileUsesTheSameJSONFormatAsTheWorkspaceFile() throws {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "shared format"))
        let snapshot = SessionStore.Snapshot.make(from: store)

        let explicitURL = directory.appendingPathComponent("format.session")
        try SessionStore.saveSnapshot(snapshot, to: explicitURL)
        try SessionStore.save(snapshot) // writes session.json

        let workspaceURL = directory.appendingPathComponent("session.json")
        let explicitJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: explicitURL)) as? NSDictionary
        let workspaceJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: workspaceURL)) as? NSDictionary
        XCTAssertEqual(explicitJSON, workspaceJSON)
    }

    func testLoadSnapshotThrowsOnCorruptFile() throws {
        let url = directory.appendingPathComponent("corrupt.session")
        try Data("this is not JSON".utf8).write(to: url)
        XCTAssertThrowsError(try SessionStore.loadSnapshot(from: url))
    }

    func testLoadSnapshotThrowsOnMissingFile() {
        let url = directory.appendingPathComponent("does-not-exist.session")
        XCTAssertThrowsError(try SessionStore.loadSnapshot(from: url))
    }
}
