import XCTest
@testable import HexpadKit

/// `LineIndex` is a performance wrapper around line math that the rest of the
/// app already depends on through `GutterGeometry`. These tests pin the
/// equivalence contract: for every input, every caret position and every line
/// number, the index must answer exactly what `GutterGeometry` answers.
final class LineIndexTests: XCTestCase {

    // MARK: - Deterministic random text generation

    /// SplitMix64: deterministic across runs so a failure is reproducible.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A mix of line terminators, multi-byte scalars, astral emoji, combining
    /// sequences and a NUL byte. CR/CRLF are deliberately present even though
    /// the editor normalises them: the contract is about raw string input.
    private let alphabet = [
        "a", "b", "c", "Z", "0", " ",
        "\n", "\r", "\r\n", "\t",
        "é", "日", "😀", "👨‍👩‍👧‍👦", "\u{0}"
    ]

    private func randomText(units: ClosedRange<Int>, using rng: inout SeededGenerator) -> String {
        let count = Int.random(in: units, using: &rng)
        var text = ""
        for _ in 0..<count {
            text += alphabet.randomElement(using: &rng)!
        }
        return text
    }

    private func assertEquivalent(_ index: LineIndex, _ text: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let utf16Count = text.utf16.count
        XCTAssertEqual(index.textLength, utf16Count, "textLength", file: file, line: line)
        XCTAssertEqual(index.count, GutterGeometry.lineCount(in: text), "count", file: file, line: line)
        XCTAssertEqual(index.lineStarts.first, 0, "starts must begin at 0", file: file, line: line)
        for (a, b) in zip(index.lineStarts, index.lineStarts.dropFirst()) {
            XCTAssertLessThan(a, b, "line starts must be strictly increasing", file: file, line: line)
        }

        // Every in-bounds caret position, plus out-of-bounds probes.
        for position in 0...utf16Count {
            XCTAssertEqual(index.line(of: position),
                           GutterGeometry.logicalLine(of: position, in: text),
                           "line(of: \(position)) for \(debugText(text))", file: file, line: line)
        }
        for position in [-5, -1, utf16Count + 1, utf16Count + 1_000] {
            XCTAssertEqual(index.line(of: position),
                           GutterGeometry.logicalLine(of: position, in: text),
                           "clamped line(of: \(position)) for \(debugText(text))", file: file, line: line)
        }

        // Every valid line number, plus past-the-end and non-positive probes.
        for lineNumber in 1...(index.count + 3) {
            XCTAssertEqual(index.firstCharIndex(of: lineNumber),
                           GutterGeometry.firstCharIndex(of: lineNumber, in: text),
                           "firstCharIndex(of: \(lineNumber)) for \(debugText(text))", file: file, line: line)
        }
        for lineNumber in [-3, 0] {
            XCTAssertEqual(index.firstCharIndex(of: lineNumber), 0,
                           "non-positive line numbers map to 0", file: file, line: line)
        }

        // Every line's start must resolve back to that same line.
        for lineNumber in 1...index.count {
            XCTAssertEqual(index.line(of: index.firstCharIndex(of: lineNumber)), lineNumber,
                           "round-trip line \(lineNumber) for \(debugText(text))", file: file, line: line)
        }
    }

    private func debugText(_ text: String) -> String {
        String(reflecting: text)
    }

    // MARK: - Equivalence with GutterGeometry

    func testMatchesGutterGeometryOnRandomTexts() {
        var rng = SeededGenerator(seed: 0x5EED_1234_ABCD_0001)
        for iteration in 0..<250 {
            let text = randomText(units: 0...50, using: &rng)
            assertEquivalent(LineIndex(text), text)
            if iteration == 0 {
                // Explicitly cover the degenerate case at least once.
                assertEquivalent(LineIndex(""), "")
            }
        }
    }

    func testMatchesGutterGeometryOnLongMultilineText() {
        var rng = SeededGenerator(seed: 0x0BAD_F00D_2026_1111)
        let text = randomText(units: 500...800, using: &rng)
        assertEquivalent(LineIndex(text), text)
    }

    func testEmptyTextIsOneLine() {
        assertEquivalent(LineIndex(""), "")
        XCTAssertEqual(LineIndex("").lineStarts, [0])
        XCTAssertEqual(LineIndex("").count, 1)
        XCTAssertEqual(LineIndex("").textLength, 0)
    }

    func testTrailingNewlineOpensFinalEmptyLine() {
        let text = "a\nb\n"
        let index = LineIndex(text)
        assertEquivalent(index, text)
        XCTAssertEqual(index.count, 3)
        XCTAssertEqual(index.lineStarts, [0, 2, 4])
        XCTAssertEqual(index.line(of: 4), 3)
        XCTAssertEqual(index.firstCharIndex(of: 3), 4)
    }

    func testOnlyNewlines() {
        let text = "\n\n\n"
        let index = LineIndex(text)
        assertEquivalent(index, text)
        XCTAssertEqual(index.lineStarts, [0, 1, 2, 3])
        XCTAssertEqual(index.count, 4)
        XCTAssertEqual(index.line(of: 0), 1)
        XCTAssertEqual(index.line(of: 3), 4)
        XCTAssertEqual(index.firstCharIndex(of: 4), 3)
    }

    func testCRAndCRLFCountOnlyLineFeeds() {
        // "a\r\nb\rc\n": LF at UTF-16 offsets 2 and 6. The lone CR at 4 and the
        // CR of the CRLF pair are ordinary characters on their lines, exactly
        // as GutterGeometry treats them.
        let text = "a\r\nb\rc\n"
        let index = LineIndex(text)
        assertEquivalent(index, text)
        XCTAssertEqual(index.lineStarts, [0, 3, 7])
        XCTAssertEqual(index.line(of: 2), 1) // between CR and LF
        XCTAssertEqual(index.line(of: 3), 2) // after CRLF
        XCTAssertEqual(index.line(of: 7), 3)
        XCTAssertEqual(index.firstCharIndex(of: 2), 3)
    }

    func testUnicodeUsesUTF16Offsets() {
        // Leading astral character occupies two UTF-16 units.
        let text = "😀\nnext"
        let index = LineIndex(text)
        assertEquivalent(index, text)
        XCTAssertEqual(index.firstCharIndex(of: 1), 0)
        XCTAssertEqual(index.firstCharIndex(of: 2), 3) // "\n" is at offset 2
        XCTAssertEqual(index.line(of: 3), 2)
    }

    // MARK: - Binary search edge cases

    func testFirstLineAndLastLine() {
        let text = "one\ntwo\nthree"
        let index = LineIndex(text)
        XCTAssertEqual(index.count, 3)
        XCTAssertEqual(index.line(of: 0), 1)
        XCTAssertEqual(index.firstCharIndex(of: 1), 0)
        XCTAssertEqual(index.line(of: text.utf16.count), 3)
        XCTAssertEqual(index.firstCharIndex(of: 3), GutterGeometry.firstCharIndex(of: 3, in: text))
    }

    func testPositionsAtLineBoundaries() {
        let text = "abc\ndef\n"
        let index = LineIndex(text)
        XCTAssertEqual(index.lineStarts, [0, 4, 8])

        // Each line: every position from its start to just past its end.
        XCTAssertEqual(index.line(of: 0), 1)
        XCTAssertEqual(index.line(of: 3), 1) // caret immediately before LF
        XCTAssertEqual(index.line(of: 4), 2) // caret immediately after LF
        XCTAssertEqual(index.line(of: 7), 2)
        XCTAssertEqual(index.line(of: 8), 3) // final empty line

        XCTAssertEqual(index.firstCharIndex(of: 1), 0)
        XCTAssertEqual(index.firstCharIndex(of: 2), 4)
        XCTAssertEqual(index.firstCharIndex(of: 3), 8)
        XCTAssertEqual(index.firstCharIndex(of: 4), 8) // clamps to end
        XCTAssertEqual(index.firstCharIndex(of: 99), 8)
    }

    func testPositionsBeyondEndClampToLastLine() {
        let text = "only\ntwo"
        let index = LineIndex(text)
        XCTAssertEqual(index.line(of: text.utf16.count), 2)
        XCTAssertEqual(index.line(of: text.utf16.count + 10), 2)
        XCTAssertEqual(index.firstCharIndex(of: 99), text.utf16.count)
    }

    func testNegativeInputs() {
        let index = LineIndex("a\nb")
        XCTAssertEqual(index.line(of: -1), 1)
        XCTAssertEqual(index.line(of: Int.min), 1)
        XCTAssertEqual(index.firstCharIndex(of: -1), 0)
        XCTAssertEqual(index.firstCharIndex(of: 0), 0)
    }

    /// A wide index still resolves boundaries correctly; guards the midpoint
    /// arithmetic against off-by-one drift on larger arrays.
    func testManyLinesResolveCorrectly() {
        let count = 5_000
        let text = (1...count).map(String.init).joined(separator: "\n")
        let index = LineIndex(text)
        XCTAssertEqual(index.count, count)
        XCTAssertEqual(index.line(of: 0), 1)
        XCTAssertEqual(index.firstCharIndex(of: 1), 0)
        XCTAssertEqual(index.line(of: text.utf16.count), count)
        for lineNumber in stride(from: 1, through: count, by: 97) {
            XCTAssertEqual(index.line(of: index.firstCharIndex(of: lineNumber)), lineNumber)
        }
    }
}
