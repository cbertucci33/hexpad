import XCTest
@testable import HexpadKit

final class HashSHA512Tests: XCTestCase {

    // MARK: - HashKit fixtures

    private let unicodeText = "héllo 世界 🚀"

    /// Bytes that exercise zero, high-bit and ASCII values in the `Data` overload.
    private let binaryData = Data([0x00, 0x01, 0xFE, 0xFF])

    // MARK: - HashKit: SHA-512

    func testSHA512KnownAnswers() {
        XCTAssertEqual(
            HashKit.sha512("abc"),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        )
        XCTAssertEqual(
            HashKit.sha512(""),
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
                + "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        )
        XCTAssertEqual(
            HashKit.sha512(unicodeText),
            "3a4132d140c3449de95b169fe6ca54e2603523d0493a5b79419a7cee4103cad9"
                + "4b642af56b746f8217840c5417571ed43cee41099bd611ee149eee97b6d82a9a"
        )
    }

    func testSHA512DataOverloadKnownAnswer() {
        XCTAssertEqual(
            HashKit.sha512(binaryData),
            "4be83ccadf8eac0eae59651f3c2eb4a60342235ee1bd08366f3b2a40bd045c59"
                + "10e69380c53454090c243965b1571eab2760663d9c52f291f9be20d82e4dc45a"
        )
    }

    func testStringAndDataOverloadsAgree() {
        XCTAssertEqual(HashKit.sha512(unicodeText), HashKit.sha512(Data(unicodeText.utf8)))
        XCTAssertEqual(HashKit.sha512(""), HashKit.sha512(Data()))
    }

    func testDigestIsLowercaseHexOfExpectedLength() {
        let digest = HashKit.sha512("abc")
        XCTAssertEqual(digest.count, 128)
        XCTAssertEqual(digest, digest.lowercased())
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Registry

    func testSHA512CommandIsRegisteredInToolCommands() {
        let identifiers = CommandRegistry.default.toolCommands.map(\.identifier)
        XCTAssertEqual(identifiers, [
            "hash-md5", "hash-sha1", "hash-sha256", "hash-sha512",
            "insert-date", "insert-time", "insert-datetime"
        ])
        XCTAssertEqual(CommandRegistry.default.command(for: "hash-sha512")?.title, "SHA-512")
    }

    func testSHA512CommandDigestsWholeBufferAtCaret() {
        let result = CommandRegistry.default.execute("hash-sha512",
                                                     text: "abc",
                                                     selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(result?.text, "a" + HashKit.sha512("abc") + "bc")
        XCTAssertEqual(result?.selection, NSRange(location: 129, length: 0))
    }

    func testSHA512CommandDigestsSelectionAndInsertsAtCaret() {
        let result = CommandRegistry.default.execute("hash-sha512",
                                                     text: "abc",
                                                     selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(result?.text, HashKit.sha512("abc") + "abc")
        XCTAssertEqual(result?.selection, NSRange(location: 128, length: 0))
    }
}
