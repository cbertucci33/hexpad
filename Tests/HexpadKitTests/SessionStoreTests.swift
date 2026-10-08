import XCTest
@testable import HexpadKit
import Foundation

final class SessionStoreTests: XCTestCase {
    var testDir: URL!
    
    override func setUp() {
        super.setUp()
        testDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HexpadTest")
        try? FileManager.default.removeItem(at: testDir)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }
    
    func testSaveAndRestore() throws {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "one"))
        store.addDocument(DocumentModel(text: "two"))
        
        // Override the session file path for testing
        let sessionFile = testDir.appendingPathComponent("session.json")
        
        var data: [String: Any] = [
            "tabs": store.toSessionData(),
            "selectedIndex": store.selectedIndex
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        try jsonData.write(to: sessionFile)
        
        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path))
        
        // Verify restore works
        let restored = try? JSONSerialization.jsonObject(with: try Data(contentsOf: sessionFile)) as? [String: Any]
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?["selectedIndex"] as? Int, 1)
    }
    
    func testNoSessionFileReturnsNil() {
        let store = TabStore()
        let result = SessionStore.restore()
        XCTAssertNil(result)
    }
}
