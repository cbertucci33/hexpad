import XCTest
@testable import HexpadKit

/// Wave 5A: the remainder of the N++ Line Operations plus the missing Blank
/// Operations conversions. Every op is exercised as a pure Kit transform first,
/// then through the registry lookup/execution path. The registry groups added by
/// this wave stay out of the pinned legacy groups, so existing menu-shape tests
/// are unaffected.
final class LineOpsWave5Tests: XCTestCase {

    private let caret = NSRange(location: 0, length: 0)

    // MARK: - Sort by length

    func testSortByLengthAscendingOrdersByCharacterCountAndKeepsTiesStable() {
        XCTAssertEqual(LineOps.sortLinesByLengthAscending("ccc\na\nbb\ndddd"), "a\nbb\nccc\ndddd")
        XCTAssertEqual(LineOps.sortLinesByLengthAscending("aa\nbb\nc"), "c\naa\nbb")
    }

    func testSortByLengthDescendingOrdersByCharacterCountAndKeepsTiesStable() {
        XCTAssertEqual(LineOps.sortLinesByLengthDescending("ccc\na\nbb\ndddd"), "dddd\nccc\nbb\na")
        XCTAssertEqual(LineOps.sortLinesByLengthDescending("aa\nbb\nc"), "aa\nbb\nc")
    }

    func testSortByLengthEdges() {
        XCTAssertEqual(LineOps.sortLinesByLengthAscending(""), "")
        XCTAssertEqual(LineOps.sortLinesByLengthDescending(""), "")
        XCTAssertEqual(LineOps.sortLinesByLengthAscending("single"), "single")
        XCTAssertEqual(LineOps.sortLinesByLengthDescending("single"), "single")
        let alreadySorted = "a\nbb\nccc"
        XCTAssertEqual(LineOps.sortLinesByLengthAscending(alreadySorted), alreadySorted)
        XCTAssertEqual(LineOps.sortLinesByLengthDescending("ccc\nbb\na"), "ccc\nbb\na")
    }

    // MARK: - Lexicographic ignoring case

    func testSortLexIgnoringCaseAscending() {
        XCTAssertEqual(LineOps.sortLinesLexicographicallyIgnoringCaseAscending("banana\nApple\ncherry\napple"),
                       "Apple\napple\nbanana\ncherry")
        XCTAssertEqual(LineOps.sortLinesLexicographicallyIgnoringCaseAscending("Z\na"), "a\nZ")
    }

    func testSortLexIgnoringCaseDescending() {
        XCTAssertEqual(LineOps.sortLinesLexicographicallyIgnoringCaseDescending("banana\nApple\ncherry\napple"),
                       "cherry\nbanana\nApple\napple")
        XCTAssertEqual(LineOps.sortLinesLexicographicallyIgnoringCaseDescending("a\nZ"), "Z\na")
    }

    func testSortLexIgnoringCaseEdges() {
        XCTAssertEqual(LineOps.sortLinesLexicographicallyIgnoringCaseAscending(""), "")
        XCTAssertEqual(LineOps.sortLinesLexicographicallyIgnoringCaseDescending(""), "")
        XCTAssertEqual(LineOps.sortLinesLexicographicallyIgnoringCaseAscending("Solo"), "Solo")
        XCTAssertEqual(LineOps.sortLinesLexicographicallyIgnoringCaseDescending("Solo"), "Solo")
        let sorted = "A\nb\nC"
        XCTAssertEqual(LineOps.sortLinesLexicographicallyIgnoringCaseAscending(sorted), sorted)
    }

    // MARK: - Decimal comma sort

    func testSortDecimalCommaAscendingComparesCommaDecimalsByValue() {
        XCTAssertEqual(LineOps.sortLinesDecimalCommaAscending("10,234\n9,876\n2,5"),
                       "2,5\n9,876\n10,234")
        XCTAssertEqual(LineOps.sortLinesDecimalCommaAscending("3\n10,5\n2"), "2\n3\n10,5")
    }

    func testSortDecimalCommaDescendingAndTrailingNonNumbers() {
        XCTAssertEqual(LineOps.sortLinesDecimalCommaDescending("10,234\n9,876\n2,5"),
                       "10,234\n9,876\n2,5")
        XCTAssertEqual(LineOps.sortLinesDecimalCommaAscending("1,5\nzebra\n0,9"), "0,9\n1,5\nzebra")
        XCTAssertEqual(LineOps.sortLinesDecimalCommaDescending("1,5\nzebra\n0,9"), "1,5\n0,9\nzebra")
    }

    func testSortDecimalCommaEdges() {
        XCTAssertEqual(LineOps.sortLinesDecimalCommaAscending(""), "")
        XCTAssertEqual(LineOps.sortLinesDecimalCommaDescending(""), "")
        XCTAssertEqual(LineOps.sortLinesDecimalCommaAscending("7,25"), "7,25")
        let alreadySorted = "1,1\n2,02\n10,5"
        XCTAssertEqual(LineOps.sortLinesDecimalCommaAscending(alreadySorted), alreadySorted)
    }

    // MARK: - Locale-aware sort

    func testSortLocaleAwareUsesLinguisticNumericComparison() {
        // localizedStandardCompare treats digit runs as numbers, unlike the
        // codepoint-based lex sort, and ignores case.
        XCTAssertEqual(LineOps.sortLinesLocaleAwareAscending("10\n2\n1"), "1\n2\n10")
        XCTAssertEqual(LineOps.sortLinesLocaleAwareAscending("banana\nApple\ncherry"),
                       "Apple\nbanana\ncherry")
    }

    func testSortLocaleAwareDescendingAndEdges() {
        XCTAssertEqual(LineOps.sortLinesLocaleAwareDescending("10\n2\n1"), "10\n2\n1")
        XCTAssertEqual(LineOps.sortLinesLocaleAwareAscending(""), "")
        XCTAssertEqual(LineOps.sortLinesLocaleAwareDescending(""), "")
        XCTAssertEqual(LineOps.sortLinesLocaleAwareAscending("Solo"), "Solo")
        XCTAssertEqual(LineOps.sortLinesLocaleAwareDescending("Solo"), "Solo")
    }

    // MARK: - Randomize

    func testRandomizePreservesTheExactLineMultiset() {
        let input = "alpha\nbeta\ngamma\ndelta"
        for seed: UInt64 in 1...25 {
            let output = LineOps.randomizeLines(input, seed: seed)
            XCTAssertEqual(output.components(separatedBy: "\n").sorted(),
                           input.components(separatedBy: "\n").sorted(),
                           "seed \(seed) must only permute lines")
        }
    }

    func testRandomizeIsDeterministicForASeedAndCanReorder() {
        let input = "alpha\nbeta\ngamma\ndelta"
        XCTAssertEqual(LineOps.randomizeLines(input, seed: 7), LineOps.randomizeLines(input, seed: 7))
        let outputs = (1...25).map { LineOps.randomizeLines(input, seed: $0) }
        XCTAssertTrue(outputs.contains { $0 != input }, "some seed must actually reorder lines")
    }

    func testRandomizeEdges() {
        XCTAssertEqual(LineOps.randomizeLines(""), "")
        XCTAssertEqual(LineOps.randomizeLines("solo"), "solo")
        XCTAssertEqual(LineOps.randomizeLines("solo", seed: 3), "solo")
        XCTAssertEqual(LineOps.randomizeLines("a\nb", seed: 3).components(separatedBy: "\n").sorted(), ["a", "b"])
    }

    // MARK: - Split lines

    func testSplitLinesAtWrapColumnBreaksLongLinesIntoChunks() {
        XCTAssertEqual(LineOps.splitLines("abcdefghij", atColumn: 4), "abcd\nefgh\nij")
        XCTAssertEqual(LineOps.splitLines("abc\nabcdefgh", atColumn: 4), "abc\nabcd\nefgh")
        XCTAssertEqual(LineOps.splitLines("abcdefgh", atColumn: 4), "abcd\nefgh")
    }

    func testSplitLinesEdges() {
        XCTAssertEqual(LineOps.splitLines("", atColumn: 4), "")
        XCTAssertEqual(LineOps.splitLines("abc", atColumn: 4), "abc")
        XCTAssertEqual(LineOps.splitLines("abc", atColumn: 0), "abc")
        XCTAssertEqual(LineOps.splitLines("abc", atColumn: -1), "abc")
        // Columns count Characters, so an emoji cluster is never cut in half.
        XCTAssertEqual(LineOps.splitLines("😀😀😀", atColumn: 2), "😀😀\n😀")
    }

    // MARK: - Join lines

    func testJoinSelectedLinesFoldsLinesWithSpaces() {
        XCTAssertEqual(LineOps.joinSelectedLines("a\nb\nc"), "a b c")
        XCTAssertEqual(LineOps.joinSelectedLines("one\ntwo"), "one two")
    }

    func testJoinSelectedLinesEdges() {
        XCTAssertEqual(LineOps.joinSelectedLines(""), "")
        XCTAssertEqual(LineOps.joinSelectedLines("solo"), "solo")
        XCTAssertEqual(LineOps.joinSelectedLines("already one line"), "already one line")
    }

    // MARK: - TAB to Space

    func testTabToSpaceExpandsToTabStopsEverywhere() {
        XCTAssertEqual(LineOps.tabToSpace("a\tb", tabWidth: 4), "a   b")
        XCTAssertEqual(LineOps.tabToSpace("\tX\tab", tabWidth: 4), "    X   ab")
    }

    func testTabToSpaceLeadingOnlyLeavesInteriorTabsAlone() {
        XCTAssertEqual(LineOps.tabToSpace("  \tX\tY", tabWidth: 4, leadingOnly: true), "    X\tY")
        XCTAssertEqual(LineOps.tabToSpace("\t\tvalue\tend", tabWidth: 2, leadingOnly: true), "    value\tend")
    }

    func testTabToSpaceEdges() {
        XCTAssertEqual(LineOps.tabToSpace(""), "")
        XCTAssertEqual(LineOps.tabToSpace("solo"), "solo")
        XCTAssertEqual(LineOps.tabToSpace("a\tb\na b", tabWidth: 2), "a b\na b")
        XCTAssertEqual(LineOps.tabToSpace(" \t \tx", tabWidth: 4, leadingOnly: true), "        x")
    }

    // MARK: - Space to TAB

    func testSpaceToTabConsolidatesFullTabStops() {
        XCTAssertEqual(LineOps.spaceToTab("    X", tabWidth: 4), "\tX")
        XCTAssertEqual(LineOps.spaceToTab("        X", tabWidth: 4), "\t\tX")
        XCTAssertEqual(LineOps.spaceToTab("a   b", tabWidth: 4), "a\tb")
    }

    func testSpaceToTabLeadingOnlyLeavesInteriorSpacesAlone() {
        XCTAssertEqual(LineOps.spaceToTab("    X    Y", tabWidth: 4, leadingOnly: true), "\tX    Y")
        XCTAssertEqual(LineOps.spaceToTab("  X", tabWidth: 4, leadingOnly: true), "  X")
    }

    func testSpaceToTabEdges() {
        XCTAssertEqual(LineOps.spaceToTab(""), "")
        XCTAssertEqual(LineOps.spaceToTab("solo"), "solo")
        XCTAssertEqual(LineOps.spaceToTab("  X\n    Y", tabWidth: 2), "\tX\n\t\tY")
        XCTAssertEqual(LineOps.spaceToTab("\tX    Y", tabWidth: 4, leadingOnly: true), "\tX    Y",
                       "leading-only leaves interior spaces alone")
    }

    // MARK: - Trim both and EOL to Space

    func testTrimBothAndEOLToSpaceTrimsEachLineThenFolds() {
        XCTAssertEqual(LineOps.trimBothAndEOLToSpace("  a  \n\tb\t\nc"), "a b c")
        XCTAssertEqual(LineOps.trimBothAndEOLToSpace(" \n a \n"), " a ")
    }

    func testTrimBothAndEOLToSpaceEdges() {
        XCTAssertEqual(LineOps.trimBothAndEOLToSpace(""), "")
        XCTAssertEqual(LineOps.trimBothAndEOLToSpace("  solo  "), "solo")
        XCTAssertEqual(LineOps.trimBothAndEOLToSpace("a\nb"), "a b")
    }

    // MARK: - Registry wiring

    func testEveryNewLineOpResolvesThroughTheRegistry() {
        let registry = CommandRegistry.default
        let expected: [String: String] = [
            "sort-lines-by-length-ascending": "Sort Lines By Length Ascending",
            "sort-lines-by-length-descending": "Sort Lines By Length Descending",
            "sort-lines-lexicographically-ascending-ignoring-case": "Sort Lines Lex. Ascending Ignoring Case",
            "sort-lines-lexicographically-descending-ignoring-case": "Sort Lines Lex. Descending Ignoring Case",
            "sort-lines-decimal-comma-ascending": "Sort Lines As Decimals (Comma) Ascending",
            "sort-lines-decimal-comma-descending": "Sort Lines As Decimals (Comma) Descending",
            "sort-lines-locale-ascending": "Sort Lines In Locale Order Ascending",
            "sort-lines-locale-descending": "Sort Lines In Locale Order Descending",
            "randomize-line-order": "Randomize Line Order",
            "split-lines": "Split Lines",
            "join-lines": "Join Lines"
        ]
        for (identifier, title) in expected {
            XCTAssertEqual(registry.command(for: identifier)?.title, title, identifier)
            XCTAssertFalse(registry.allCommands.contains { $0.identifier == identifier },
                           "\(identifier) stays outside the pinned legacy groups")
            XCTAssertFalse(registry.lineOpCommands.contains { $0.identifier == identifier },
                           "\(identifier) stays outside the pinned lineOpCommands array")
        }
        // Dictionary order is not registration order — compare as sets.
        XCTAssertEqual(Set(registry.lineOpsRemainderCommands.map(\.identifier)),
                       Set(expected.keys))
    }

    func testEveryNewBlankOpResolvesThroughTheRegistry() {
        let registry = CommandRegistry.default
        let expected: [String: String] = [
            "trim-both-and-eol-to-space": "Trim both and EOL to Space",
            "tab-to-space": "TAB to Space",
            "tab-to-space-leading": "TAB to Space (Leading)",
            "space-to-tab-all": "Space to TAB (All)",
            "space-to-tab-leading": "Space to TAB (Leading)"
        ]
        for (identifier, title) in expected {
            XCTAssertEqual(registry.command(for: identifier)?.title, title, identifier)
            XCTAssertFalse(registry.allCommands.contains { $0.identifier == identifier },
                           "\(identifier) stays outside the pinned legacy groups")
        }
        // EOL-to-Space already existed in Wave 3A and is intentionally not re-added.
        XCTAssertEqual(registry.command(for: "eol-to-space")?.title, "EOL to Space")
    }

    func testNewCommandsExecuteThroughTheRegistry() {
        let registry = CommandRegistry.default
        XCTAssertEqual(registry.execute("sort-lines-by-length-ascending",
                                        text: "ccc\na\nbb", selection: caret)?.text, "a\nbb\nccc")
        XCTAssertEqual(registry.execute("sort-lines-decimal-comma-descending",
                                        text: "2,5\n10,234", selection: caret)?.text, "10,234\n2,5")
        XCTAssertEqual(registry.execute("sort-lines-lexicographically-ascending-ignoring-case",
                                        text: "Z\na", selection: caret)?.text, "a\nZ")
        XCTAssertEqual(registry.execute("sort-lines-locale-ascending",
                                        text: "10\n2", selection: caret)?.text, "2\n10")
        XCTAssertEqual(registry.execute("join-lines", text: "a\nb", selection: caret)?.text, "a b")
        XCTAssertEqual(registry.execute("tab-to-space", text: "a\tb", selection: caret)?.text, "a   b")
        XCTAssertEqual(registry.execute("space-to-tab-all", text: "    X", selection: caret)?.text, "\tX")
        XCTAssertEqual(registry.execute("trim-both-and-eol-to-space",
                                        text: "  a  \nb", selection: caret)?.text, "a b")
    }

    func testSplitLinesRegistryCommandDefaultsTo80AndAcceptsAParameter() {
        let registry = CommandRegistry.default
        let long = String(repeating: "x", count: 81)
        XCTAssertEqual(registry.execute("split-lines", text: long, selection: caret)?.text,
                       String(repeating: "x", count: 80) + "\nx")
        XCTAssertEqual(registry.execute("split-lines", parameter: "4",
                                        text: "abcdefghij", selection: caret)?.text,
                       "abcd\nefgh\nij")
        XCTAssertEqual(registry.execute("split-lines", parameter: "bogus",
                                        text: "abcdefghij", selection: caret)?.text,
                       "abcdefghij", "bogus parameter falls back to column 80; a 10-char line is unchanged")
    }

    func testNewCommandsTransformOnlyTheSelection() {
        let text = "a\tb\n  c  \nd"
        let selection = NSRange(location: 0, length: 4) // "a\tb\n"
        let result = CommandRegistry.default.execute("tab-to-space", text: text, selection: selection)
        XCTAssertEqual(result?.text, "a   b\n  c  \nd")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 6),
                       "\"a\\tb\\n\" becomes \"a   b\\n\" — 6 chars")

        let join = CommandRegistry.default.execute("join-lines", text: "a\nb\nc",
                                                   selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(join?.text, "a b\nc")
        XCTAssertEqual(join?.selection, NSRange(location: 0, length: 3))
    }

    func testExistingOpsAreNotDuplicated() {
        // These were already shipped and are deliberately left untouched.
        let registry = CommandRegistry.default
        XCTAssertEqual(LineOps.sortAscending("b\nA"), "A\nb")
        XCTAssertEqual(LineOps.joinLines("a\nb"), "a b")
        XCTAssertEqual(LineOps.eolToWhitespace("a\nb"), "a b")
        XCTAssertEqual(registry.execute("eol-to-space", text: "a\nb", selection: caret)?.text, "a b")
        XCTAssertEqual(registry.execute("sort-lines-ascending", text: "b\na", selection: caret)?.text, "a\nb")
    }
}
