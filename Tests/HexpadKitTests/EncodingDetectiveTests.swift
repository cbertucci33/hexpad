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
    
    func testValidMultiByteUTF8NoBOM() {
        // "é" = U+00E9 -> bytes C3 A9 (valid UTF-8, no BOM)
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0xC3, 0xA9])
        XCTAssertEqual(EncodingDetective.detect(data), "UTF-8")
    }
    
    func testCP1252HighByteTextNoBOM() {
        // Smart-quote bytes 0x93 0x94 0x92 are invalid UTF-8 alone; high-byte pattern -> CP1252
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x93, 0x94, 0x92])
        XCTAssertEqual(EncodingDetective.detect(data), "Windows-1252")
    }
    
    func testUTF16WithoutBOMByNullDensity() {
        // "He" in UTF-16LE without BOM: 48 00 65 00 -> half null bytes
        let data = Data([0x48, 0x00, 0x65, 0x00])
        XCTAssertEqual(EncodingDetective.detect(data), "UTF-16")
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
    
    // Round-trip: every encodingName(from:) value must nsEncoding back to the same UInt.
    func testEncodingNameRoundTrip() {
        let values: [UInt] = [
            String.Encoding.utf8.rawValue,
            String.Encoding.utf16.rawValue,
            String.Encoding.utf16BigEndian.rawValue,
            String.Encoding.utf16LittleEndian.rawValue,
            String.Encoding.utf32BigEndian.rawValue,
            String.Encoding.utf32LittleEndian.rawValue,
            String.Encoding.ascii.rawValue,
            String.Encoding.isoLatin1.rawValue,
            String.Encoding.isoLatin2.rawValue,
            String.Encoding.windowsCP1252.rawValue,
            String.Encoding.windowsCP1251.rawValue,
            String.Encoding.windowsCP1254.rawValue,
            String.Encoding.shiftJIS.rawValue,
            String.Encoding.japaneseEUC.rawValue,
            String.Encoding.iso2022JP.rawValue,
            String.Encoding.macOSRoman.rawValue,
            String.Encoding.nonLossyASCII.rawValue,
        ]
        for raw in values {
            let name = EncodingDetective.encodingName(from: raw)
            XCTAssertEqual(EncodingDetective.nsEncoding(from: name), raw,
                           "name '\(name)' did not round-trip")
        }
        // Both dashed and undashed spellings must resolve to the same encoding.
        XCTAssertEqual(EncodingDetective.nsEncoding(from: "UTF-16-LE"), EncodingDetective.nsEncoding(from: "UTF-16LE"))
        XCTAssertEqual(EncodingDetective.nsEncoding(from: "UTF-16-LE"), String.Encoding.utf16LittleEndian.rawValue)
        XCTAssertEqual(EncodingDetective.nsEncoding(from: "Shift_JIS"), String.Encoding.shiftJIS.rawValue)
        XCTAssertEqual(EncodingDetective.nsEncoding(from: "MacRoman"), String.Encoding.macOSRoman.rawValue)
        XCTAssertEqual(EncodingDetective.nsEncoding(from: "Non-Lossy ASCII"), String.Encoding.nonLossyASCII.rawValue)
    }
}
