import XCTest
@testable import HexpadKit

final class CaseOpsTests: XCTestCase {

    // MARK: - UPPERCASE / lowercase

    func testUppercaseConvertsSelectionOnly() {
        let text = "hello WORLD, ok"
        let result = CaseOps.uppercase(text, selection: NSRange(location: 0, length: 11))

        XCTAssertEqual(result.text, "HELLO WORLD, ok")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 11))
    }

    func testLowercaseConvertsSelectionOnly() {
        let text = "hello WORLD, ok"
        let result = CaseOps.lowercase(text, selection: NSRange(location: 6, length: 5))

        XCTAssertEqual(result.text, "hello world, ok")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 5))
    }

    // MARK: - Proper Case

    func testProperCaseTitleCasesEachWord() {
        let result = CaseOps.properCase("hello wORLD", selection: NSRange(location: 0, length: 11))
        XCTAssertEqual(result.text, "Hello World")
    }

    func testProperCaseSplitsWordsOnNonLetters() {
        let result = CaseOps.properCase("foo-bar baz", selection: NSRange(location: 0, length: 11))
        XCTAssertEqual(result.text, "Foo-Bar Baz")
    }

    func testProperCaseBlendKeepsAllCapsWords() {
        let result = CaseOps.properCaseBlend("hello NASA and ESA",
                                            selection: NSRange(location: 0, length: 18))
        XCTAssertEqual(result.text, "Hello NASA And ESA")
    }

    func testProperCaseBlendStillTitleCasesMixedAndLowercaseWords() {
        let result = CaseOps.properCaseBlend("hello wORLD iPAD",
                                            selection: NSRange(location: 0, length: 16))
        XCTAssertEqual(result.text, "Hello World Ipad")
    }

    func testProperCaseWithoutBlendLowercasesAcronyms() {
        let result = CaseOps.properCase("hello NASA", selection: NSRange(location: 0, length: 10))
        XCTAssertEqual(result.text, "Hello Nasa")
    }

    // MARK: - Sentence case

    func testSentenceCaseCapitalizesSentenceStartsAndLowercasesTheRest() {
        let phrase = "hello WORLD. this is a TEST!"
        let result = CaseOps.sentenceCase(phrase, selection: NSRange(location: 0, length: (phrase as NSString).length))
        XCTAssertEqual(result.text, "Hello world. This is a test!")
    }

    func testSentenceCaseTreatsLineBreaksAsSentenceStarts() {
        let phrase = "first line\nsecond LINE"
        let result = CaseOps.sentenceCase(phrase, selection: NSRange(location: 0, length: (phrase as NSString).length))
        XCTAssertEqual(result.text, "First line\nSecond line")
    }

    func testSentenceCaseIgnoresLeadingQuotesWhenCapitalizing() {
        let phrase = "\"hello there\""
        let result = CaseOps.sentenceCase(phrase, selection: NSRange(location: 0, length: (phrase as NSString).length))
        XCTAssertEqual(result.text, "\"Hello there\"")
    }

    func testSentenceCaseBlendKeepsAllCapsWords() {
        let phrase = "hello NASA. NASA is HERE. next"
        let result = CaseOps.sentenceCaseBlend(phrase, selection: NSRange(location: 0, length: (phrase as NSString).length))
        XCTAssertEqual(result.text, "Hello NASA. NASA is HERE. Next")
    }

    // MARK: - iNVERT cASE / ranDOm CasE

    func testInvertCaseSwapsEveryCasedCharacter() {
        let result = CaseOps.invertCase("Hello World 42!",
                                        selection: NSRange(location: 0, length: 15))
        XCTAssertEqual(result.text, "hELLO wORLD 42!")
    }

    func testRandomCaseUsesTheRollForEachCasedCharacterOnly() {
        var rolls: [Bool] = [true, false, true]
        let result = CaseOps.randomCase("a-b c!",
                                        selection: NSRange(location: 0, length: 5),
                                        roll: { rolls.removeFirst() })

        XCTAssertEqual(result.text, "A-b C!")
        XCTAssertTrue(rolls.isEmpty, "the roll is only consumed by cased characters")
    }

    func testRandomCaseRollsCanForceUpperOrLower() {
        XCTAssertEqual(CaseOps.randomCase("abc 123",
                                          selection: NSRange(location: 0, length: 7),
                                          roll: { true }).text,
                       "ABC 123")
        XCTAssertEqual(CaseOps.randomCase("abc 123",
                                          selection: NSRange(location: 0, length: 7),
                                          roll: { false }).text,
                       "abc 123")
    }

    // MARK: - Word-at-caret fallback

    func testUppercaseWithCaretInsideWordConvertsThatWord() {
        let result = CaseOps.uppercase("alpha beta gamma", selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(result.text, "ALPHA beta gamma")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 5))
    }

    func testCaretAtEndOfWordConvertsThePrecedingWord() {
        let result = CaseOps.uppercase("alpha beta", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(result.text, "ALPHA beta")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 5))
    }

    func testCaretAtStartOfWordConvertsTheFollowingWord() {
        let result = CaseOps.lowercase("ALPHA BETA", selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(result.text, "ALPHA beta")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 4))
    }

    func testCaretAtDocumentEndConvertsTheLastWord() {
        let text = "alpha beta gamma"
        let result = CaseOps.invertCase(text, selection: NSRange(location: (text as NSString).length, length: 0))
        XCTAssertEqual(result.text, "alpha beta GAMMA")
        XCTAssertEqual(result.selection, NSRange(location: 11, length: 5))
    }

    func testCaretOnWhitespaceConvertsTheWordBeforeIt() {
        let result = CaseOps.uppercase("alpha beta", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(result.text, "ALPHA beta")
    }

    func testCaretOnNonWordTextIsANoOp() {
        let result = CaseOps.uppercase("!!!", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(result.text, "!!!")
        XCTAssertEqual(result.selection, NSRange(location: 1, length: 0))
    }

    func testUnderscoreAndDigitsBelongToTheCaretWord() {
        let result = CaseOps.uppercase("foo_bar x", selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(result.text, "FOO_BAR x")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 7))
    }

    // MARK: - Selection mapping

    func testSelectionMapsOntoTheConvertedWord() {
        let result = CaseOps.uppercase("alpha beta", selection: NSRange(location: 6, length: 4))
        XCTAssertEqual(result.text, "alpha BETA")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 4))
    }

    func testSelectionCoversExpandedUppercaseMapping() {
        let result = CaseOps.uppercase("straße", selection: NSRange(location: 0, length: (("straße") as NSString).length))
        XCTAssertEqual(result.text, "STRASSE")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 7))
    }

    // MARK: - Registry

    func testCaseCommandsAreRegisteredInMenuOrder() {
        XCTAssertEqual(CommandRegistry.default.caseCommands.map(\.identifier), [
            "case-uppercase",
            "case-lowercase",
            "case-proper",
            "case-proper-blend",
            "case-sentence",
            "case-sentence-blend",
            "case-invert",
            "case-random"
        ])
    }

    func testCaseCommandTitlesMatchNotepadPlusPlus() {
        XCTAssertEqual(CommandRegistry.default.caseCommands.map(\.title), [
            "UPPERCASE",
            "lowercase",
            "Proper Case",
            "Proper Case (blend)",
            "Sentence case",
            "Sentence case (blend)",
            "iNVERT cASE",
            "ranDOm CasE"
        ])
    }

    func testRegistryRunsCaseCommandsThroughTheSharedPath() {
        let registry = CommandRegistry.default

        XCTAssertEqual(registry.execute("case-uppercase",
                                        text: "alpha beta",
                                        selection: NSRange(location: 0, length: 5))?.text,
                       "ALPHA beta")
        XCTAssertEqual(registry.execute("case-lowercase",
                                        text: "ALPHA BETA",
                                        selection: NSRange(location: 0, length: 5))?.text,
                       "alpha BETA")
        XCTAssertEqual(registry.execute("case-proper",
                                        text: "hello world",
                                        selection: NSRange(location: 0, length: 11))?.text,
                       "Hello World")
        XCTAssertEqual(registry.execute("case-proper-blend",
                                        text: "hello NASA",
                                        selection: NSRange(location: 0, length: 10))?.text,
                       "Hello NASA")
        XCTAssertEqual(registry.execute("case-sentence",
                                        text: "hello there. next",
                                        selection: NSRange(location: 0, length: 17))?.text,
                       "Hello there. Next")
        XCTAssertEqual(registry.execute("case-sentence-blend",
                                        text: "hello NASA. next",
                                        selection: NSRange(location: 0, length: 16))?.text,
                       "Hello NASA. Next")
        XCTAssertEqual(registry.execute("case-invert",
                                        text: "Hello",
                                        selection: NSRange(location: 0, length: 5))?.text,
                       "hELLO")
        XCTAssertNotNil(registry.command(for: "case-random"))
    }

    func testRegistryCaseCommandFallsBackToTheCaretWord() {
        let result = CommandRegistry.default.execute("case-uppercase",
                                                     text: "alpha beta",
                                                     selection: NSRange(location: 8, length: 0))
        XCTAssertEqual(result?.text, "alpha BETA")
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 4))
    }

    func testCaseCommandsArePartOfAllCommands() {
        let ids = CommandRegistry.default.allCommands.map(\.identifier)
        for id in CommandRegistry.default.caseCommands.map(\.identifier) {
            XCTAssertTrue(ids.contains(id), "missing \(id) from allCommands")
        }
    }
}
