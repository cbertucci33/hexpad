import XCTest
@testable import HexpadKit

final class ToolsTests: XCTestCase {

    // MARK: - HashKit fixtures

    private let unicodeText = "héllo 世界 🚀"

    /// Bytes that exercise zero, high-bit and ASCII values in the `Data` overloads.
    private let binaryData = Data([0x00, 0x01, 0xFE, 0xFF])

    // MARK: - HashKit: MD5

    func testMD5KnownAnswers() {
        XCTAssertEqual(HashKit.md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(HashKit.md5(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(HashKit.md5(unicodeText), "acc0dafbe629072192420af27ded2fc4")
    }

    // MARK: - HashKit: SHA-1

    func testSHA1KnownAnswers() {
        XCTAssertEqual(HashKit.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(HashKit.sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(HashKit.sha1(unicodeText), "e9b7059f54aa12e99ae44e98976e4766fb732ffd")
    }

    // MARK: - HashKit: SHA-256

    func testSHA256KnownAnswers() {
        XCTAssertEqual(
            HashKit.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            HashKit.sha256(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            HashKit.sha256(unicodeText),
            "f8f7614aca7d882238f2793ab44db4adffa5d901e3231a7b9e3723e817f3921f"
        )
    }

    // MARK: - HashKit: Data overloads

    func testDataOverloadsMatchKnownAnswers() {
        XCTAssertEqual(HashKit.md5(binaryData), "f129ac2d8a0ee74923012d1c8ed83a86")
        XCTAssertEqual(HashKit.sha1(binaryData), "302c1f256c8e9ebb5edf0822b473d0cd3d2ce84c")
        XCTAssertEqual(
            HashKit.sha256(binaryData),
            "c5dbae22661af6db18a1f676db82a7ef7de46d27c3a263a872f00478b0d99fc4"
        )
    }

    func testStringOverloadsHashUTF8Bytes() {
        XCTAssertEqual(HashKit.md5(unicodeText), HashKit.md5(Data(unicodeText.utf8)))
        XCTAssertEqual(HashKit.sha1(unicodeText), HashKit.sha1(Data(unicodeText.utf8)))
        XCTAssertEqual(HashKit.sha256(unicodeText), HashKit.sha256(Data(unicodeText.utf8)))
    }

    func testEmptyDataMatchesEmptyString() {
        XCTAssertEqual(HashKit.md5(Data()), HashKit.md5(""))
        XCTAssertEqual(HashKit.sha1(Data()), HashKit.sha1(""))
        XCTAssertEqual(HashKit.sha256(Data()), HashKit.sha256(""))
    }

    func testDigestsAreLowercaseHexOfExpectedLength() {
        let digests = [
            (HashKit.md5("abc"), 32),
            (HashKit.sha1("abc"), 40),
            (HashKit.sha256("abc"), 64)
        ]
        for (digest, length) in digests {
            XCTAssertEqual(digest.count, length)
            XCTAssertEqual(digest, digest.lowercased())
            XCTAssertTrue(digest.allSatisfy { $0.isHexDigit })
        }
    }

    // MARK: - DateTimeInsert fixtures

    /// 2021-03-04 05:06:07 UTC.
    private func fixedDate() throws -> Date {
        var components = DateComponents()
        components.year = 2021
        components.month = 3
        components.day = 4
        components.hour = 5
        components.minute = 6
        components.second = 7

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return try XCTUnwrap(calendar.date(from: components))
    }

    private let posix = Locale(identifier: "en_US_POSIX")
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let pacific = TimeZone(secondsFromGMT: -8 * 3600)!

    /// ICU may separate the AM/PM marker with a narrow no-break space; normalise
    /// all space variants so assertions do not depend on the ICU version.
    private func normalizingSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - DateTimeInsert: short styles

    func testShortDateUsesLocale() throws {
        let date = try fixedDate()
        XCTAssertEqual(
            DateTimeInsert.shortDate(date, locale: posix, timeZone: utc),
            "3/4/21"
        )
        XCTAssertEqual(
            DateTimeInsert.shortDate(date, locale: Locale(identifier: "en_GB"), timeZone: utc),
            "04/03/2021"
        )
    }

    func testShortTimeUsesLocaleAndTimeZone() throws {
        let date = try fixedDate()
        XCTAssertEqual(
            normalizingSpaces(DateTimeInsert.shortTime(date, locale: posix, timeZone: utc)),
            "5:06 AM"
        )
        XCTAssertEqual(
            normalizingSpaces(DateTimeInsert.shortTime(date, locale: posix, timeZone: pacific)),
            "9:06 PM"
        )
    }

    func testShortDateTimeCombinesDateAndTime() throws {
        let date = try fixedDate()
        XCTAssertEqual(
            normalizingSpaces(DateTimeInsert.shortDateTime(date, locale: posix, timeZone: utc)),
            "3/4/21, 5:06 AM"
        )
        XCTAssertEqual(
            normalizingSpaces(DateTimeInsert.shortDateTime(date, locale: posix, timeZone: pacific)),
            "3/3/21, 9:06 PM"
        )
    }

    // MARK: - DateTimeInsert: custom patterns

    func testCustomPattern() throws {
        let date = try fixedDate()
        XCTAssertEqual(
            DateTimeInsert.formatted(date, pattern: "yyyy-MM-dd HH:mm:ss", locale: posix, timeZone: utc),
            "2021-03-04 05:06:07"
        )
        XCTAssertEqual(
            DateTimeInsert.formatted(date, pattern: "HH:mm", locale: posix, timeZone: utc),
            "05:06"
        )
        XCTAssertEqual(
            normalizingSpaces(
                DateTimeInsert.formatted(
                    date,
                    pattern: "EEEE, MMMM d, yyyy 'at' h:mm:ss a",
                    locale: posix,
                    timeZone: utc
                )
            ),
            "Thursday, March 4, 2021 at 5:06:07 AM"
        )
    }

    func testCustomPatternSupportsQuotedLiterals() throws {
        let date = try fixedDate()
        XCTAssertEqual(
            DateTimeInsert.formatted(
                date,
                pattern: "yyyy'年'MM'月'dd'日'",
                locale: posix,
                timeZone: utc
            ),
            "2021年03月04日"
        )
        XCTAssertEqual(
            DateTimeInsert.formatted(date, pattern: "yyyy'it''s'MM", locale: posix, timeZone: utc),
            "2021it's03"
        )
    }

    func testCustomPatternUsesLocaleForNames() throws {
        let date = try fixedDate()
        XCTAssertEqual(
            DateTimeInsert.formatted(date, pattern: "MMMM d", locale: posix, timeZone: utc),
            "March 4"
        )
        XCTAssertEqual(
            DateTimeInsert.formatted(
                date,
                pattern: "MMMM d",
                locale: Locale(identifier: "de_DE"),
                timeZone: utc
            ),
            "März 4"
        )
    }

    func testCustomPatternUsesTimeZone() throws {
        let date = try fixedDate()
        XCTAssertEqual(
            DateTimeInsert.formatted(date, pattern: "yyyy-MM-dd HH:mm:ss", locale: posix, timeZone: pacific),
            "2021-03-03 21:06:07"
        )
        XCTAssertEqual(
            DateTimeInsert.formatted(date, pattern: "yyyy-MM-dd", locale: posix, timeZone: pacific),
            "2021-03-03"
        )
    }

    func testFormattingIsDeterministicForFixedInputs() throws {
        let date = try fixedDate()
        let first = DateTimeInsert.shortDateTime(date, locale: posix, timeZone: utc)
        let second = DateTimeInsert.shortDateTime(date, locale: posix, timeZone: utc)
        XCTAssertEqual(first, second)
    }
}
