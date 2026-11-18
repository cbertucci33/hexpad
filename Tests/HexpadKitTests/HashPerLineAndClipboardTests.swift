import XCTest
@testable import HexpadKit

/// Tests for the T24a per-line hash mode: `HashKit.digestPerLine` and the four
/// `hash-*-per-line` Tools commands that use it.
final class HashPerLineAndClipboardTests: XCTestCase {

    // MARK: - Fixtures

    /// Two lines with independently known single-line digests.
    private let twoLines = "abc\ndef"

    private let md5abc = "900150983cd24fb0d6963f7d28e17f72"
    private let md5def = "4ed9407630eb1000c0f6b63842defa7d"
    private let sha512abc = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
        + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
    private let sha512def = "40a855bf0a93c1019d75dd5b59cd8157608811dd75c5977e07f3bc4be0cad98b"
        + "22dde4db9ddb429fc2ad3cf9ca379fedf6c1dc4d4bb8829f10c2f0ee04a66663"

    // MARK: - HashKit: digestPerLine

    func testDigestPerLineMD5KnownAnswers() {
        XCTAssertEqual(HashKit.digestPerLine(twoLines, HashKit.md5),
                       md5abc + "\n" + md5def)
        // Each line's digest matches hashing that line on its own.
        XCTAssertEqual(HashKit.digestPerLine("abc", HashKit.md5), md5abc)
        XCTAssertEqual(HashKit.digestPerLine("def", HashKit.md5), md5def)
    }

    func testDigestPerLineSHA512KnownAnswers() {
        XCTAssertEqual(HashKit.digestPerLine(twoLines, HashKit.sha512),
                       sha512abc + "\n" + sha512def)
        XCTAssertEqual(HashKit.digestPerLine("abc", HashKit.sha512), sha512abc)
        XCTAssertEqual(HashKit.digestPerLine("def", HashKit.sha512), sha512def)
    }

    func testDigestPerLinePreservesEmptyLines() {
        // Blank lines stay blank rather than becoming the digest of "".
        XCTAssertEqual(HashKit.digestPerLine("abc\n\n\ndef", HashKit.md5),
                       md5abc + "\n\n\n" + md5def)
        XCTAssertEqual(HashKit.digestPerLine("\n", HashKit.md5), "\n")
        XCTAssertEqual(HashKit.digestPerLine("", HashKit.md5), "")
    }

    func testDigestPerLineAddsNoTrailingNewline() {
        let result = HashKit.digestPerLine(twoLines, HashKit.md5)
        XCTAssertFalse(result.hasSuffix("\n"))

        // An existing trailing newline is retained, but not duplicated.
        XCTAssertEqual(HashKit.digestPerLine("abc\n", HashKit.md5), md5abc + "\n")
    }

    func testDigestPerLinePreservesCRLF() {
        // The CR belongs to the line terminator, not to the hashed content.
        XCTAssertEqual(HashKit.digestPerLine("abc\r\ndef", HashKit.md5),
                       md5abc + "\r\n" + md5def)
    }

    func testDigestPerLineIsLowercaseHex() {
        let result = HashKit.digestPerLine(twoLines, HashKit.sha512)
        XCTAssertEqual(result, result.lowercased())
        XCTAssertTrue(result.split(separator: "\n").allSatisfy { $0.allSatisfy(\.isHexDigit) })
    }

    // MARK: - Registry

    func testPerLineCommandsAreRegisteredInToolCommands() {
        let registry = CommandRegistry.default
        XCTAssertEqual(registry.toolCommands.map(\.identifier), [
            "hash-md5", "hash-sha1", "hash-sha256", "hash-sha512",
            "hash-md5-per-line", "hash-sha1-per-line",
            "hash-sha256-per-line", "hash-sha512-per-line",
            "insert-date", "insert-time", "insert-datetime"
        ])

        let expectedTitles = [
            "hash-md5-per-line": "MD5 Per-line",
            "hash-sha1-per-line": "SHA-1 Per-line",
            "hash-sha256-per-line": "SHA-256 Per-line",
            "hash-sha512-per-line": "SHA-512 Per-line"
        ]
        for (identifier, title) in expectedTitles {
            XCTAssertEqual(registry.command(for: identifier)?.title, title, identifier)
        }
    }

    func testPerLineCommandInsertsPerLineDigestAtCaret() {
        let result = CommandRegistry.default.execute("hash-sha512-per-line",
                                                     text: twoLines,
                                                     selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(result?.text, sha512abc + "\n" + sha512def + twoLines)
    }
}
