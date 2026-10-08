import XCTest
@testable import HexpadKit

final class EncodingDetectiveTests: XCTestCase {
    func testUTF8WithBOM() {
        let data = Data([0xEF, 0xBB, 0xBF, 0x48, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertEqual(EncodingDetective.detect(data), "UTF-8")
    }
    
    func testUTF16LEWithBOM() {
        let data = Data([0xFF, 0xFE, 0x48, 0x00, 0x65, 0x00, 0x6C, 0x00])
        XCTAssertEqual(EncodingDetective.detect(data), "UTF-16LE")
    }
    
    func testUTF16BEWithBOM() {
        let data = Data([0xFE, 0xFF, 0x00, 0x48, 0x00, 0x65, 0x00, 0x6C])
        XCTAssertEqual(EncodingDetective.detect(data), "UTF-16BE")
    }
    
    func testUTF8NoBOM() {
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertEqual(EncodingDetective.detect(data), "UTF-8")
    }
    
    func testEmptyData() {
        let data = Data()
        XCTAssertEqual(EncodingDetective.detect(data), "UTF-8")
    }
    
    func testEncodingNameMapping() {
        XCTAssertEqual(EncodingDetective.encodingName(from: String.Encoding.utf8.rawValue), "UTF-8")
        XCTAssertEqual(EncodingDetective.encodingName(from: String.Encoding.unicode.rawValue), "UTF-16")
    }
    
    func testNSEncodingMapping() {
        XCTAssertEqual(EncodingDetective.nsEncoding(from: "UTF-8"), String.Encoding.utf8.rawValue)
        XCTAssertEqual(EncodingDetective.nsEncoding(from: "UTF-16"), String.Encoding.unicode.rawValue)
        XCTAssertEqual(EncodingDetective.nsEncoding(from: "unknown"), String.Encoding.utf8.rawValue)
    }
}
