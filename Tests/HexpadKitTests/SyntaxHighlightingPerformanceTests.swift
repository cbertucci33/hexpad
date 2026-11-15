import XCTest
@testable import HexpadKit

/// Performance gates for the viewport/incremental highlighting pipeline.
/// These print measured wall-clock times so a regression shows up as both a
/// failing threshold and a number in the test log.
final class SyntaxHighlightingPerformanceTests: XCTestCase {

    private func makePythonSource(byteCount: Int) -> String {
        let line = "def compute_value_42(x: int) -> int:\n"
            + "    # comment with some words\n"
            + "    value = x * 42 + len(\"sample string\")\n"
            + "    return value\n\n"
        var lines: [String] = []
        lines.reserveCapacity(byteCount / line.utf8.count + 1)
        var size = 0
        while size < byteCount {
            lines.append(line)
            size += line.utf8.count
        }
        return lines.joined()
    }

    func testFullTokenize100KBPythonUnder200ms() {
        let source = makePythonSource(byteCount: 100_000)
        XCTAssertGreaterThan(source.utf8.count, 99_000)

        let start = CFAbsoluteTimeGetCurrent()
        let tokens = SyntaxTokenizer.tokenize(source, language: .python)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print(String(format: "[benchmark] full tokenize 100KB Python: %.1f ms (%d tokens)",
                     elapsed * 1000, tokens.count))
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertLessThan(elapsed, 0.2, "full tokenize must stay under 200ms")
    }

    func testIncrementalKeystrokeOn100KBPythonUnder50ms() {
        var source = makePythonSource(byteCount: 100_000)
        let store = TokenStore(language: .python)

        let caret = (source as NSString).length / 2
        let viewport = NSRange(location: caret, length: min(2_000, (source as NSString).length - caret))
        store.ensureTokens(for: source, range: viewport)

        let editLocation = caret
        source = (source as NSString).replacingCharacters(in: NSRange(location: editLocation, length: 0),
                                                          with: "x")
        let newLength = (source as NSString).length

        let start = CFAbsoluteTimeGetCurrent()
        store.update(text: source,
                     language: .python,
                     editedRange: NSRange(location: editLocation, length: 1))
        store.ensureTokens(for: source,
                           range: NSRange(location: editLocation,
                                          length: min(2_000, newLength - editLocation)))
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print(String(format: "[benchmark] incremental keystroke 100KB Python: %.1f ms",
                     elapsed * 1000))
        XCTAssertLessThan(elapsed, 0.05, "incremental update must stay under 50ms")
    }

    func testLargeFileKeepsOnlyViewportTokens() {
        let source = makePythonSource(byteCount: 1_100_000)
        let store = TokenStore(language: .python)
        let viewport = NSRange(location: (source as NSString).length / 2, length: 2_000)

        let start = CFAbsoluteTimeGetCurrent()
        let target = store.ensureTokens(for: source, range: viewport)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print(String(format: "[benchmark] large-file viewport 1.1MB Python: %.1f ms (%d tokens, %d chars)",
                     elapsed * 1000, store.tokens.count, target.length))
        XCTAssertTrue(store.isLargeFile)
        XCTAssertLessThan(target.length, 20_000, "large file must tokenize a viewport, not the whole file")
        XCTAssertLessThan(elapsed, 0.05)
    }
}
