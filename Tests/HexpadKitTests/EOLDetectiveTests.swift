import XCTest
@testable import HexpadKit

final class EOLDetectiveTests: XCTestCase {

    // MARK: - Text detection

    func testCRLFDetected() {
        XCTAssertEqual(EOLDetective.detect("one\r\ntwo\r\nthree"), "CRLF")
        XCTAssertFalse(EOLDetective.isMixed("one\r\ntwo\r\nthree"))
    }

    func testLFDetected() {
        XCTAssertEqual(EOLDetective.detect("one\ntwo\nthree"), "LF")
        XCTAssertFalse(EOLDetective.isMixed("one\ntwo\nthree"))
    }

    func testCRDetected() {
        XCTAssertEqual(EOLDetective.detect("one\rtwo\rthree"), "CR")
        XCTAssertFalse(EOLDetective.isMixed("one\rtwo\rthree"))
    }

    func testCRLFIsNotCountedAsCRAndLF() {
        // If CRLF were split, this would look mixed instead of purely CRLF.
        XCTAssertEqual(EOLDetective.detect("a\r\n\r\nb\r\n"), "CRLF")
        XCTAssertFalse(EOLDetective.isMixed("a\r\n\r\nb\r\n"))
    }

    func testMixedReportsDominantStyle() {
        // Two CRLF terminators versus one LF: CRLF is dominant.
        XCTAssertEqual(EOLDetective.detect("a\r\nb\r\nc\nd"), "CRLF")
        XCTAssertTrue(EOLDetective.isMixed("a\r\nb\r\nc\nd"))
    }

    func testMixedTieGoesToFirstTerminator() {
        // One terminator of each style; the first terminator wins the tie.
        XCTAssertEqual(EOLDetective.detect("a\nb\r\nc"), "LF")
        XCTAssertTrue(EOLDetective.isMixed("a\nb\r\nc"))

        XCTAssertEqual(EOLDetective.detect("a\r\nb\nc"), "CRLF")
        XCTAssertTrue(EOLDetective.isMixed("a\r\nb\nc"))
    }

    func testEmptyDocumentDefaultsToLF() {
        XCTAssertEqual(EOLDetective.detect(""), "LF")
        XCTAssertFalse(EOLDetective.isMixed(""))
    }

    func testTextWithoutLineTerminatorDefaultsToLF() {
        XCTAssertEqual(EOLDetective.detect("single line"), "LF")
        XCTAssertFalse(EOLDetective.isMixed("single line"))
    }

    func testTrailingTerminatorIsDetected() {
        XCTAssertEqual(EOLDetective.detect("one\r\n"), "CRLF")
        XCTAssertEqual(EOLDetective.detect("one\n"), "LF")
        XCTAssertEqual(EOLDetective.detect("one\r"), "CR")
    }

    // MARK: - Data detection

    func testDataDetectsCRLF() {
        let data = Data("one\r\ntwo\r\n".utf8)
        XCTAssertEqual(EOLDetective.detect(data), "CRLF")
        XCTAssertFalse(EOLDetective.isMixed(data))
    }

    func testDataDetectsLF() {
        let data = Data("one\ntwo\n".utf8)
        XCTAssertEqual(EOLDetective.detect(data), "LF")
    }

    func testDataDetectsCR() {
        let data = Data("one\rtwo\r".utf8)
        XCTAssertEqual(EOLDetective.detect(data), "CR")
    }

    func testEmptyDataDefaultsToLF() {
        XCTAssertEqual(EOLDetective.detect(Data()), "LF")
        XCTAssertFalse(EOLDetective.isMixed(Data()))
    }

    func testDataDetectsMixed() {
        let data = Data("one\r\ntwo\nthree\r\n".utf8)
        XCTAssertEqual(EOLDetective.detect(data), "CRLF")
        XCTAssertTrue(EOLDetective.isMixed(data))
    }

    func testMultibyteUTF8BytesAreNotMistakenForTerminators() {
        // "é" is C3 A9 and "日" contains continuation bytes in the 0x80-0xBF
        // range. Only the actual CRLF should count.
        let data = Data("café\r\n日本語\r\n".utf8)
        XCTAssertEqual(EOLDetective.detect(data), "CRLF")
        XCTAssertFalse(EOLDetective.isMixed(data))
    }

    // MARK: - Conversion

    func testConvertingToEachStyle() {
        let mixed = "a\r\nb\nc\rd"
        XCTAssertEqual(EOLDetective.converting(mixed, to: "LF"), "a\nb\nc\nd")
        XCTAssertEqual(EOLDetective.converting(mixed, to: "CRLF"), "a\r\nb\r\nc\r\nd")
        XCTAssertEqual(EOLDetective.converting(mixed, to: "CR"), "a\rb\rc\rd")
    }

    func testConvertingIsIdempotent() {
        let crlf = "a\r\nb\r\n"
        XCTAssertEqual(EOLDetective.converting(crlf, to: "CRLF"), crlf)
        XCTAssertEqual(EOLDetective.converting(EOLDetective.converting(crlf, to: "CRLF"), to: "CRLF"), crlf)
    }

    func testConvertingUnknownStyleFallsBackToLF() {
        XCTAssertEqual(EOLDetective.converting("a\r\nb", to: "Mixed"), "a\nb")
    }
}
