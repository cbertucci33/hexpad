import XCTest
@testable import HexpadKit

final class TabStoreTests: XCTestCase {
    func testInitialState() {
        let store = TabStore()
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.selectedDocument)
        XCTAssertEqual(store.selectedIndex, 0)
    }
    
    func testAddDocument() {
        let store = TabStore()
        let doc = DocumentModel(text: "hello")
        store.addDocument(doc)
        
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.selectedDocument?.text, "hello")
        XCTAssertEqual(store.selectedIndex, 0)
    }
    
    func testSelectDocument() {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "one"))
        store.addDocument(DocumentModel(text: "two"))
        store.addDocument(DocumentModel(text: "three"))
        
        store.selectDocument(at: 1)
        XCTAssertEqual(store.selectedDocument?.text, "two")
        XCTAssertEqual(store.selectedIndex, 1)
    }
    
    func testRemoveDocument() {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "one"))
        store.addDocument(DocumentModel(text: "two"))
        store.addDocument(DocumentModel(text: "three"))
        
        store.removeDocument(at: 1)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.selectedDocument?.text, "three")
    }
    
    func testRemoveLastDocument() {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "only"))
        store.removeDocument(at: 0)
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.selectedIndex, 0)
    }
    
    func testMoveDocument() {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "a"))
        store.addDocument(DocumentModel(text: "b"))
        store.addDocument(DocumentModel(text: "c"))
        
        store.moveDocument(from: 0, to: 2)
        XCTAssertEqual(store.documents[0].text, "b")
        XCTAssertEqual(store.documents[1].text, "c")
        XCTAssertEqual(store.documents[2].text, "a")
    }
    
    func testCloseAll() {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "one"))
        store.addDocument(DocumentModel(text: "two"))
        store.closeAll()
        XCTAssertTrue(store.isEmpty)
    }

    /// Bulk-close scopes resolve against tab order, with left/right relative to
    /// the active tab and "unchanged" filtered by the dirty flag.
    func testCloseScopesFollowTabOrderAndDirtyState() {
        let store = TabStore()
        let a = DocumentModel(text: "a")
        let b = DocumentModel(text: "b")
        let c = DocumentModel(text: "c")
        let d = DocumentModel(text: "d")
        [a, b, c, d].forEach(store.addDocument)
        store.selectDocument(at: 2) // c is active

        XCTAssertEqual(store.documents(matching: .allButActive).map(\.text), ["a", "b", "d"])
        XCTAssertEqual(store.documents(matching: .allButPinned).map(\.text), ["a", "b", "d"],
                       "no pinning yet: behaves like all-but-active")
        XCTAssertEqual(store.documents(matching: .toLeftOfActive).map(\.text), ["a", "b"])
        XCTAssertEqual(store.documents(matching: .toRightOfActive).map(\.text), ["d"])
        XCTAssertEqual(store.documents(matching: .unchanged).map(\.text), ["a", "b", "c", "d"])

        b.setModified(true)
        XCTAssertEqual(store.documents(matching: .unchanged).map(\.text), ["a", "c", "d"],
                       "dirty tabs stay open")

        // Edges: nothing on one side of the active tab, empty store.
        store.selectDocument(at: 0)
        XCTAssertTrue(store.documents(matching: .toLeftOfActive).isEmpty)
        XCTAssertEqual(store.documents(matching: .toRightOfActive).map(\.text), ["b", "c", "d"])
        store.selectDocument(at: 3)
        XCTAssertTrue(store.documents(matching: .toRightOfActive).isEmpty)

        store.closeAll()
        for scope: TabCloseScope in [.allButActive, .allButPinned, .toLeftOfActive, .toRightOfActive, .unchanged] {
            XCTAssertTrue(store.documents(matching: scope).isEmpty)
        }
    }
    
    func testSessionRoundTrip() {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "one"))
        store.addDocument(DocumentModel(text: "two"))
        
        let data = store.toSessionData()
        let restored = TabStore.fromSessionData(data)
        
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.documents[0].text, "one")
        XCTAssertEqual(restored.documents[1].text, "two")
    }
}
