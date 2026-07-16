import XCTest
@testable import WDSAppCore

final class TokenEstimatorTests: XCTestCase {
    func testEmptyAndWhitespaceEstimateToZero() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        XCTAssertEqual(TokenEstimator.estimate("   "), 0)
        XCTAssertEqual(TokenEstimator.estimate("\t \t"), 0)
    }

    func testHangulUsesSyllableWeight() {
        // 5 syllables * 1.2 = 6.0
        XCTAssertEqual(TokenEstimator.estimate("안녕하세요"), 6)
        // 1 syllable * 1.2 = 1.2 -> 1
        XCTAssertEqual(TokenEstimator.estimate("안"), 1)
    }

    func testLatinRunsApproximateCharsPerToken() {
        // 5 letters * 0.28 = 1.4 -> 1
        XCTAssertEqual(TokenEstimator.estimate("hello"), 1)
        // 10 letters * 0.28 = 2.8 -> 3 (space folds in)
        XCTAssertEqual(TokenEstimator.estimate("hello world"), 3)
    }

    func testDigitsUseDigitWeight() {
        // abc: 3 * 0.28 = 0.84; 123: 3 * 0.4 = 1.2; total 2.04 -> 2
        XCTAssertEqual(TokenEstimator.estimate("abc123"), 2)
    }

    func testMixedScriptSumsPerBucket() {
        // 5 Hangul * 1.2 + 5 latin * 0.28 = 6.0 + 1.4 = 7.4 -> 7
        XCTAssertEqual(TokenEstimator.estimate("안녕하세요 hello"), 7)
    }

    func testNewlinesEachCostAToken() {
        XCTAssertEqual(TokenEstimator.estimate("\n\n"), 2)
    }

    func testNonEmptyContentIsAtLeastOneToken() {
        // A single cheap scalar sums under 0.5 but must not collapse to the
        // empty/whitespace sentinel of 0.
        XCTAssertEqual(TokenEstimator.estimate("I"), 1)
        XCTAssertEqual(TokenEstimator.estimate("5"), 1)
        XCTAssertEqual(TokenEstimator.estimate("!"), 1)
    }

    func testCRLFCountsAsOneLineBreak() {
        XCTAssertEqual(TokenEstimator.estimate("\r\n"), 1)
        // Identical text differing only in line-ending style estimates equally.
        XCTAssertEqual(TokenEstimator.estimate("a\r\nb"), TokenEstimator.estimate("a\nb"))
    }

    func testEmojiUsesOtherWeight() {
        // otherSymbol / non-alphabetic scalar -> 2.0
        XCTAssertEqual(TokenEstimator.estimate("😀"), 2)
    }

    func testHabitualProfanityPhraseIsCheapButNonZero() {
        // 씨발: 2 * 1.2 = 2.4 -> 2
        XCTAssertEqual(TokenEstimator.estimate("씨발"), 2)
    }

    func testLongerDraftEstimatesAtLeastAsMuchAsItsSubstring() {
        let whole = TokenEstimator.estimate("혹시 가능하시다면 봐주세요")
        let part = TokenEstimator.estimate("봐주세요")
        XCTAssertGreaterThanOrEqual(whole, part)
        XCTAssertGreaterThan(whole, 0)
    }

    func testCustomWeightsAreHonored() {
        let weights = TokenEstimator.Weights(
            hangulSyllable: 2.0,
            hangulJamo: 1.0,
            cjk: 1.0,
            latin: 0.28,
            digit: 0.4,
            punctuation: 0.35,
            newline: 1.0,
            whitespace: 0.0,
            other: 2.0
        )
        let estimator = TokenEstimator(weights: weights)
        // 2 syllables * 2.0 = 4.0
        XCTAssertEqual(estimator.estimate("안녕"), 4)
        // default weights give 2 * 1.2 = 2.4 -> 2
        XCTAssertEqual(TokenEstimator.estimate("안녕"), 2)
    }
}
