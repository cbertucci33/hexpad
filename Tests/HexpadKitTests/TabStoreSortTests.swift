import XCTest
@testable import HexpadKit

/// W23a: Window > Sort By delegates the actual reordering to `TabStore`.
/// These tests pin each key's comparator, the "missing value sorts last" rule,
/// stability for equal keys, and the selection-follows-document contract.
final class TabStoreSortTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-tab-sort-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func makeFile(_ name: String, modified date: Date? = nil) throws -> URL {
        let url = fileURL(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        if let date {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return url
    }

    private func namedDocument(_ name: String, text: String = "") -> DocumentModel {
        let document = DocumentModel(text: text)
        document.name = name
        return document
    }

    // MARK: - Name

    func testSortByNameAscendingAndDescending() {
        let store = TabStore()
        let zebra = namedDocument("Zebra", text: "one")
        let alpha = namedDocument("alpha", text: "two")
        let beta = namedDocument("Beta", text: "three")
        [zebra, alpha, beta].forEach(store.addDocument)

        store.sortDocuments(by: .name, ascending: true)
        XCTAssertEqual(store.documents.map(\.name), ["alpha", "Beta", "Zebra"],
                       "name uses a localized, case-insensitive compare")

        store.sortDocuments(by: .name, ascending: false)
        XCTAssertEqual(store.documents.map(\.name), ["Zebra", "Beta", "alpha"])
    }

    // MARK: - Path

    func testSortByPathPutsEmptyPathsLastInBothDirections() {
        let store = TabStore()
        let zPath = DocumentModel(filePath: URL(fileURLWithPath: "/tmp/hexpad-sort-z.txt"))
        let aPath = DocumentModel(filePath: URL(fileURLWithPath: "/tmp/hexpad-sort-a.txt"))
        let untitledOne = DocumentModel(text: "untitled one")
        let untitledTwo = DocumentModel(text: "untitled two")
        [zPath, aPath, untitledOne, untitledTwo].forEach(store.addDocument)

        store.sortDocuments(by: .path, ascending: true)
        XCTAssertTrue(store.documents[0] === aPath)
        XCTAssertTrue(store.documents[1] === zPath)
        XCTAssertTrue(store.documents[2] === untitledOne)
        XCTAssertTrue(store.documents[3] === untitledTwo)

        store.sortDocuments(by: .path, ascending: false)
        XCTAssertTrue(store.documents[0] === zPath)
        XCTAssertTrue(store.documents[1] === aPath)
        XCTAssertTrue(store.documents[2] === untitledOne,
                      "an empty path stays last even when the order is reversed")
        XCTAssertTrue(store.documents[3] === untitledTwo,
                      "empty paths remain stable among themselves")
    }

    // MARK: - Type

    func testSortByTypeLowercasesExtensionsAndPutsUntitledLast() throws {
        let store = TabStore()
        let swift = DocumentModel(filePath: fileURL("b.swift"))
        let markdown = DocumentModel(filePath: fileURL("a.md"))
        let upperTxt = DocumentModel(filePath: fileURL("c.TXT"))
        let noExtOne = DocumentModel(filePath: fileURL("README"))
        let untitled = DocumentModel(text: "untitled")
        let noExtTwo = DocumentModel(filePath: fileURL("LICENSE"))
        [swift, markdown, upperTxt, noExtOne, untitled, noExtTwo].forEach(store.addDocument)

        store.sortDocuments(by: .type, ascending: true)
        XCTAssertTrue(store.documents[0] === markdown)
        XCTAssertTrue(store.documents[1] === swift)
        XCTAssertTrue(store.documents[2] === upperTxt, "extensions compare lowercased")
        XCTAssertTrue(store.documents[3] === noExtOne)
        XCTAssertTrue(store.documents[4] === untitled)
        XCTAssertTrue(store.documents[5] === noExtTwo)

        store.sortDocuments(by: .type, ascending: false)
        XCTAssertTrue(store.documents[0] === upperTxt, "extensions compare lowercased")
        XCTAssertTrue(store.documents[1] === swift)
        XCTAssertTrue(store.documents[2] === markdown)
        XCTAssertTrue(store.documents[3] === noExtOne, "no-extension stays last when reversed")
        XCTAssertTrue(store.documents[4] === untitled)
        XCTAssertTrue(store.documents[5] === noExtTwo)
    }

    // MARK: - Length

    func testSortByLengthAscendingAndDescending() {
        let store = TabStore()
        let three = DocumentModel(text: "aaa")
        let one = DocumentModel(text: "a")
        let two = DocumentModel(text: "aa")
        [three, one, two].forEach(store.addDocument)

        store.sortDocuments(by: .length, ascending: true)
        XCTAssertEqual(store.documents.map(\.text), ["a", "aa", "aaa"])

        store.sortDocuments(by: .length, ascending: false)
        XCTAssertEqual(store.documents.map(\.text), ["aaa", "aa", "a"])
    }

    // MARK: - Modified

    func testSortByModifiedPutsNeverSavedLast() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let middle = Date(timeIntervalSince1970: 2_000)
        let new = Date(timeIntervalSince1970: 3_000)

        let store = TabStore()
        let newDoc = DocumentModel(filePath: try makeFile("new.txt", modified: new))
        let untitled = DocumentModel(text: "never saved")
        let oldDoc = DocumentModel(filePath: try makeFile("old.txt", modified: old))
        let midDoc = DocumentModel(filePath: try makeFile("mid.txt", modified: middle))
        [newDoc, untitled, oldDoc, midDoc].forEach(store.addDocument)

        store.sortDocuments(by: .modified, ascending: true)
        XCTAssertEqual(store.documents.map(\.name), ["old.txt", "mid.txt", "new.txt", "Untitled"])

        store.sortDocuments(by: .modified, ascending: false)
        XCTAssertEqual(store.documents.map(\.name), ["new.txt", "mid.txt", "old.txt", "Untitled"],
                       "never-saved documents stay last when the order is reversed")
    }

    // MARK: - Selection

    func testSelectionFollowsSelectedDocumentToItsNewIndex() {
        let store = TabStore()
        let a = namedDocument("A", text: "one")
        let b = namedDocument("B", text: "two")
        let c = namedDocument("C", text: "three")
        [a, b, c].forEach(store.addDocument)
        store.selectDocument(at: 0)
        XCTAssertTrue(store.selectedDocument === a)

        store.sortDocuments(by: .name, ascending: false) // C, B, A
        XCTAssertTrue(store.selectedDocument === a)
        XCTAssertEqual(store.selectedIndex, 2)

        store.sortDocuments(by: .name, ascending: true) // A, B, C
        XCTAssertTrue(store.selectedDocument === a)
        XCTAssertEqual(store.selectedIndex, 0)
    }

    func testSortOnEmptyOrSingleTabStoreIsANoOp() {
        let store = TabStore()
        store.sortDocuments(by: .name, ascending: true)
        XCTAssertEqual(store.selectedIndex, 0, "no selection stays at zero")

        store.addDocument(DocumentModel(text: "only"))
        store.sortDocuments(by: .length, ascending: false)
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(store.selectedIndex, 0)
    }

    // MARK: - Stability

    func testSortIsStableForEqualKeys() {
        let store = TabStore()
        let first = namedDocument("Same", text: "a long buffer")
        let second = namedDocument("same", text: "x")
        let third = namedDocument("SAME", text: "mid")
        [first, second, third].forEach(store.addDocument)

        store.sortDocuments(by: .name, ascending: true)
        XCTAssertTrue(store.documents[0] === first)
        XCTAssertTrue(store.documents[1] === second)
        XCTAssertTrue(store.documents[2] === third,
                      "equal (case-insensitive) names keep their tab order")

        let lengths = TabStore()
        let l1 = DocumentModel(text: "aaa")
        let l2 = DocumentModel(text: "bbb")
        let l3 = DocumentModel(text: "ccc")
        [l1, l2, l3].forEach(lengths.addDocument)
        lengths.sortDocuments(by: .length, ascending: false)
        XCTAssertTrue(lengths.documents[0] === l1)
        XCTAssertTrue(lengths.documents[1] === l2)
        XCTAssertTrue(lengths.documents[2] === l3,
                      "equal lengths keep their tab order")
    }
}
