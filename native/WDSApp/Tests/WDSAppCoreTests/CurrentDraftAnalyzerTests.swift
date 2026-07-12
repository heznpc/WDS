import Foundation
import XCTest
@testable import WDSAppCore

final class CurrentDraftAnalyzerTests: XCTestCase {
    private let analyzer = CurrentDraftAnalyzer()

    func testFindsDetachableKoreanOpeningWithExactUTF16Range() throws {
        let draft = "아니, 이거 고치라고."
        let candidate = try XCTUnwrap(analyzer.analyze(draft).first)

        XCTAssertEqual(candidate.originalText, "아니, ")
        XCTAssertEqual(candidate.range, CurrentDraftUTF16Range(
            location: 0,
            length: ("아니, " as NSString).length
        ))
        XCTAssertEqual(candidate.reason, .detachableConversationalOpening)
        XCTAssertEqual(candidate.safety, .reviewRequired)
        XCTAssertEqual(candidate.confidence, 0.86)
        XCTAssertEqual(text(in: draft, at: candidate.range), candidate.originalText)
    }

    func testOpeningsAreAConservativeClassRatherThanOneHardcodedWord() {
        let drafts = [
            "음, 이 방향으로 다시 정리해 주세요.",
            "저기, 이 부분부터 다시 설명해 주세요.",
            "Well, please rewrite this section clearly.",
            "えっと, この部分をもう一度説明してください。",
        ]

        for draft in drafts {
            XCTAssertEqual(
                analyzer.analyze(draft).first?.reason,
                .detachableConversationalOpening,
                draft
            )
        }
    }

    func testFindsPunctuatedEmotionalPrefixWithoutNeedingRepetition() throws {
        let draft = "씨발, 이 응답의 오류 원인을 다시 설명해 주세요."
        let candidate = try XCTUnwrap(analyzer.analyze(draft).first)

        XCTAssertEqual(candidate.originalText, "씨발, ")
        XCTAssertEqual(candidate.reason, .detachableEmotionalInterjection)
        XCTAssertEqual(candidate.confidence, 0.965)
        XCTAssertEqual(candidate.safety, .high)
        XCTAssertEqual(
            deleting(candidate, from: draft),
            "이 응답의 오류 원인을 다시 설명해 주세요."
        )
    }

    func testConservativeDetachedMarkerVariantsAtPrefix() throws {
        for marker in ["시발", "씨발", "ㅅㅂ", "ㅆㅂ"] {
            let draft = "\(marker) 이 답변의 오류 원인을 다시 설명해 줘."
            let candidate = try XCTUnwrap(analyzer.analyze(draft).first, marker)

            XCTAssertEqual(candidate.originalText, marker + " ", marker)
            XCTAssertEqual(
                candidate.reason,
                .detachableEmotionalInterjection,
                marker
            )
            XCTAssertEqual(candidate.safety, .reviewRequired, marker)
            XCTAssertEqual(
                deleting(candidate, from: draft),
                "이 답변의 오류 원인을 다시 설명해 줘.",
                marker
            )
        }
    }

    func testEmotionalSuffixHasExactUTF16RangeAfterEmoji() throws {
        let draft = "🤬 이 응답의 오류 원인을 다시 설명해 줘 시발아!"
        let candidate = try XCTUnwrap(analyzer.analyze(draft).first)
        let expectedPrefix = "🤬 이 응답의 오류 원인을 다시 설명해 줘"

        XCTAssertEqual(candidate.originalText, " 시발아")
        XCTAssertEqual(candidate.range.location, (expectedPrefix as NSString).length)
        XCTAssertEqual(candidate.range.length, (" 시발아" as NSString).length)
        XCTAssertEqual(candidate.reason, .detachableEmotionalInterjection)
        XCTAssertEqual(candidate.confidence, 0.975)
        XCTAssertEqual(candidate.safety, .high)
        XCTAssertEqual(
            deleting(candidate, from: draft),
            "🤬 이 응답의 오류 원인을 다시 설명해 줘!"
        )
    }

    func testSuffixPunctuationProducesCleanRemainder() throws {
        let cases = [
            (
                "이 응답을 다시 고쳐 줘, 시발.",
                ", 시발",
                "이 응답을 다시 고쳐 줘."
            ),
            (
                "이 응답을 다시 고쳐 줘. 시발.",
                " 시발.",
                "이 응답을 다시 고쳐 줘."
            ),
        ]

        for (draft, removed, expected) in cases {
            let candidate = try XCTUnwrap(analyzer.analyze(draft).first, draft)
            XCTAssertEqual(candidate.originalText, removed, draft)
            XCTAssertEqual(deleting(candidate, from: draft), expected, draft)
        }
    }

    func testPriorHostileDraftIsCleanedOneTopCandidateAtATime() throws {
        let original = "네 작명센스 존나 구려 시발아"
        let originalCandidates = analyzer.analyze(original)
        XCTAssertEqual(originalCandidates.count, 1)
        let suffix = try XCTUnwrap(originalCandidates.first)

        XCTAssertEqual(suffix.originalText, " 시발아")
        XCTAssertEqual(suffix.reason, .detachableEmotionalInterjection)
        let withoutSuffix = deleting(suffix, from: original)
        XCTAssertEqual(withoutSuffix, "네 작명센스 존나 구려")

        let intensifier = try XCTUnwrap(analyzer.analyze(withoutSuffix).first)
        XCTAssertEqual(intensifier.originalText, "존나 ")
        XCTAssertEqual(intensifier.reason, .removableEmotionalIntensifier)
        XCTAssertEqual(intensifier.confidence, 0.885)
        XCTAssertEqual(intensifier.safety, .reviewRequired)
        XCTAssertEqual(
            deleting(intensifier, from: withoutSuffix),
            "네 작명센스 구려"
        )
    }

    func testEmotionalSuffixOutranksConversationalOpeningThenReanalysisContinues() throws {
        let original = "아니, 에 왤케 집착해 시발아"
        let first = try XCTUnwrap(analyzer.analyze(original).first)

        XCTAssertEqual(first.originalText, " 시발아")
        let withoutSuffix = deleting(first, from: original)
        let second = try XCTUnwrap(analyzer.analyze(withoutSuffix).first)
        XCTAssertEqual(second.originalText, "아니, ")
        XCTAssertEqual(second.reason, .detachableConversationalOpening)
    }

    func testInteriorInterjectionNeedsUsableContextOnBothSides() throws {
        let bareDraft = "이 답변은 시발 다시 고쳐 줘."
        let bare = try XCTUnwrap(analyzer.analyze(bareDraft).first)
        XCTAssertEqual(bare.originalText, "시발 ")
        XCTAssertEqual(bare.safety, .reviewRequired)
        XCTAssertEqual(deleting(bare, from: bareDraft), "이 답변은 다시 고쳐 줘.")

        let delimitedDraft = "이 답변은, 씨발, 다시 고쳐 줘."
        let delimited = try XCTUnwrap(analyzer.analyze(delimitedDraft).first)
        XCTAssertEqual(delimited.originalText, "씨발, ")
        XCTAssertEqual(delimited.safety, .high)
        XCTAssertEqual(
            deleting(delimited, from: delimitedDraft),
            "이 답변은, 다시 고쳐 줘."
        )
    }

    func testIntensifierOnlyTriggersBeforeIndependentNegativeEvaluation() throws {
        let cases = [
            ("이 답변이 존나 별론데 다시 작성해 줘.", "존나 "),
            ("이 결과가 ㅈㄴ 이상한데 원인을 설명해 줘.", "ㅈㄴ "),
        ]

        for (draft, removed) in cases {
            let candidate = try XCTUnwrap(analyzer.analyze(draft).first, draft)
            XCTAssertEqual(candidate.originalText, removed, draft)
            XCTAssertEqual(
                candidate.reason,
                .removableEmotionalIntensifier,
                draft
            )
        }
    }

    func testMagnitudeBearingAndInflectedIntensifiersFailClosed() {
        let drafts = [
            "이미지를 존나 크게 만들어 줘.",
            "문서를 존나 자세히 작성해 줘.",
            "존나 중요한 조건을 유지해 줘.",
            "설명을 존나 짧게 줄여 줘.",
            "이 답변은 존나게 이상하니 다시 써 줘.",
        ]

        for draft in drafts {
            XCTAssertTrue(analyzer.analyze(draft).isEmpty, draft)
        }
    }

    func testMetalinguisticAndSemanticallyMeaningfulProfanityFailsClosed() {
        let drafts = [
            "욕설을 제거해 줘.",
            "시발이라는 단어를 제거해 줘.",
            "시발 이라는 단어를 제거해 줘.",
            "문장에서 ㅅㅂ 을 지워 줘.",
            "‘존나’라는 표현의 뜻을 설명해 줘.",
            "개소리 말고 핵심만 설명해 줘.",
            "병신 취급하지 마.",
            "이게 뭔 개소리야",
            "시발점의 의미를 설명해 줘.",
        ]

        for draft in drafts {
            XCTAssertTrue(analyzer.analyze(draft).isEmpty, draft)
        }
    }

    func testStandaloneEmotionalDraftIsAWholeDraftReviewCandidate() throws {
        for draft in ["시발", "씨발!", "ㅅㅂ?!", "ㅆㅂ…", "씨발아！！", "  씨발,,  "] {
            let candidates = analyzer.analyze(draft)
            let candidate = try XCTUnwrap(candidates.first, draft)

            XCTAssertEqual(candidates.count, 1, draft)
            XCTAssertEqual(candidate.originalText, draft, draft)
            XCTAssertEqual(candidate.range, CurrentDraftUTF16Range(
                location: 0,
                length: (draft as NSString).length
            ), draft)
            XCTAssertEqual(candidate.reason, .detachableEmotionalInterjection, draft)
            XCTAssertEqual(candidate.safety, .reviewRequired, draft)
            XCTAssertEqual(deleting(candidate, from: draft), "", draft)
        }
    }

    func testShortMeaningfulOrPreservationRequestsRemainUntouched() {
        let drafts = [
            "꺼져 시발",
            "존나 구려",
            "씨발점",
            "씨발을 그대로 둬",
            "씨발 그대로 출력해.",
            "씨발! 그대로 보내.",
            "ㅅㅂ 원문 그대로 유지해.",
            "씨발 그대로 말해.",
            "씨발 그대로 읽어.",
            "씨발 그대로 복사해.",
            "\"씨발!\"",
            "‘씨발’",
            "> 씨발!",
            "/send 씨발!",
            "!echo 씨발",
            "$ printf 씨발",
        ]

        for draft in drafts {
            XCTAssertTrue(analyzer.analyze(draft).isEmpty, draft)
        }
    }

    func testOpeningRequiresCommaAndSubstantialIndependentRemainder() {
        let uncertainDrafts = [
            "아니 이거 고치라고.",
            "아니, 맞아?",
            "아니, 이것만",
            "아니, 아니라고 했습니다.",
            "아니, 아니면 다음으로 갑니다.",
            "근데, 이 부분은 중요한 대조입니다.",
            "사실, 이 부분은 의미가 달라집니다.",
        ]

        for draft in uncertainDrafts {
            XCTAssertTrue(analyzer.analyze(draft).isEmpty, draft)
        }
    }

    func testKnownPunctuatedHesitationDuplicateIsHighSafety() throws {
        let draft = "음... 음... 이 방향으로 다시 진행해 주세요."
        let candidates = analyzer.analyze(draft)
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.originalText, "음... ")
        XCTAssertEqual(candidate.reason, .duplicateHesitation)
        XCTAssertEqual(candidate.safety, .high)
        XCTAssertEqual(candidate.confidence, 0.99)
        XCTAssertEqual(text(in: draft, at: candidate.range), "음... ")
    }

    func testCommaDelimitedHesitationDuplicateRemovesOnlyFirstCopy() throws {
        let draft = "어, 어, 이 부분을 다시 작성해 주세요."
        let candidate = try XCTUnwrap(analyzer.analyze(draft).first)

        XCTAssertEqual(candidate.originalText, "어, ")
        XCTAssertEqual(
            deleting(candidate, from: draft),
            "어, 이 부분을 다시 작성해 주세요."
        )
    }

    func testRepetitionAloneNeverTriggers() {
        let drafts = [
            "정말, 정말, 이 부분은 매우 중요합니다.",
            "오류 오류 오류가 계속 발생합니다.",
            "다시 다시 작성해 주세요.",
            "음 음 이 부분을 다시 작성해 주세요.",
            "word, word, this is ordinary repetition.",
        ]

        for draft in drafts {
            XCTAssertTrue(analyzer.analyze(draft).isEmpty, draft)
        }
    }

    func testDuplicateCommaCandidatePreservesOneComma() throws {
        let draft = "이 문장은,,, 의미를 그대로 유지합니다."
        let candidate = try XCTUnwrap(analyzer.analyze(draft).first)

        XCTAssertEqual(candidate.originalText, ",,")
        XCTAssertEqual(candidate.reason, .duplicatePunctuation)
        XCTAssertEqual(candidate.safety, .high)
        XCTAssertEqual(candidate.confidence, 0.98)
        XCTAssertEqual(
            deleting(candidate, from: draft),
            "이 문장은, 의미를 그대로 유지합니다."
        )
    }

    func testDuplicateFullwidthCommaAfterEmojiUsesExactUTF16Location() throws {
        let draft = "🤔 이 문장은，， 의미를 그대로 유지합니다."
        let candidate = try XCTUnwrap(analyzer.analyze(draft).first)
        let expectedLocation = ("🤔 이 문장은，" as NSString).length

        XCTAssertEqual(candidate.originalText, "，")
        XCTAssertEqual(candidate.range.location, expectedLocation)
        XCTAssertEqual(candidate.range.length, ("，" as NSString).length)
        XCTAssertEqual(text(in: draft, at: candidate.range), "，")
        XCTAssertNotEqual("🤔 이 문장은，".count, expectedLocation)
    }

    func testPunctuationNeedsProseContextAndDoesNotNormalizeExpression() {
        let drafts = [
            "a,,b",
            "1,, 000원입니다.",
            "앗,, 다시 써 주세요.",
            "정말!! 중요한 내용입니다.",
            "정말... 중요한 내용입니다.",
            "정말?! 중요한 내용입니다.",
        ]

        for draft in drafts {
            XCTAssertTrue(analyzer.analyze(draft).isEmpty, draft)
        }
    }

    func testCodeURLsQuotesCommandsAndListsFailClosed() {
        let drafts = [
            "```swift\n아니, 이 부분을 다시 작성해 주세요.",
            "```text\n시발, 이 부분을 다시 작성해 줘.",
            "아니, https://example.com/path 를 열어 주세요.",
            "시발, https://example.com/path 를 열어 줘.",
            "> 아니, 이 부분을 다시 작성해 주세요.",
            "> 씨발, 이 부분을 다시 작성해 줘.",
            "\"아니, 이 부분을 다시 작성해 주세요.\"",
            "\"시발, 이 부분을 다시 작성해 줘.\"",
            "아니, “이 부분”을 다시 작성해 주세요.",
            "/rewrite 아니, 이 부분을 다시 작성해 주세요.",
            "/rewrite 시발, 이 부분을 다시 작성해 줘.",
            "$ git status,, 지금 실행합니다.",
            "$ echo 시발",
            "- 아니, 이 부분을 다시 작성해 주세요.",
            "- ㅅㅂ 이 부분을 다시 작성해 줘.",
            "1. 아니, 이 부분을 다시 작성해 주세요.",
            "[ ] 아니, 이 부분을 다시 작성해 주세요.",
            "## 아니, 이 부분을 다시 작성해 주세요.",
            "아니, let value = another value 입니다.",
            "아니, `inline code`를 다시 작성해 주세요.",
            "아니, 첫 문장입니다.\n    indented code",
        ]

        for draft in drafts {
            XCTAssertTrue(analyzer.analyze(draft).isEmpty, draft)
        }
    }

    func testOpeningWithDuplicateCommaRepairsPunctuationOnly() throws {
        let draft = "아니,, 이 문장을 제대로 다시 작성해 주세요."
        let candidates = analyzer.analyze(draft)
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.reason, .duplicatePunctuation)
        XCTAssertEqual(candidate.originalText, ",")
        XCTAssertEqual(deleting(candidate, from: draft), "아니, 이 문장을 제대로 다시 작성해 주세요.")
    }

    func testCandidatesAreRankedAndHardLimitedToThree() {
        let draft = "이 문장은,, 충분히 길고,, 의미도 분명하며,, 결론도 정확하고,, 설명도 있습니다."
        let candidates = CurrentDraftAnalyzer(maximumCandidates: 99).analyze(draft)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(candidates.allSatisfy { $0.reason == .duplicatePunctuation })
        XCTAssertEqual(
            candidates.map(\.range.location),
            candidates.map(\.range.location).sorted()
        )
    }

    func testConfiguredZeroCandidateLimitReturnsNothing() {
        XCTAssertTrue(
            CurrentDraftAnalyzer(maximumCandidates: 0)
                .analyze("아니, 이 문장을 다시 작성해 주세요.")
                .isEmpty
        )
    }

    func testAnalyzerDoesNotLearnAcrossCalls() {
        let analyzer = CurrentDraftAnalyzer()
        for _ in 0..<20 {
            XCTAssertTrue(analyzer.analyze("특정 말버릇이 계속 반복됩니다.").isEmpty)
        }

        XCTAssertTrue(analyzer.analyze("특정 말버릇이 새 문장에 등장합니다.").isEmpty)
        XCTAssertEqual(
            analyzer.analyze("아니, 이 문장을 다시 작성해 주세요."),
            analyzer.analyze("아니, 이 문장을 다시 작성해 주세요.")
        )
    }

    func testVeryLargeDraftFailsClosed() {
        let draft = "아니, " + String(repeating: "가", count: 32_769)
        XCTAssertTrue(analyzer.analyze(draft).isEmpty)
    }

    private func text(
        in draft: String,
        at range: CurrentDraftUTF16Range
    ) -> String {
        (draft as NSString).substring(with: NSRange(
            location: range.location,
            length: range.length
        ))
    }

    private func deleting(
        _ candidate: CurrentDraftDeletionCandidate,
        from draft: String
    ) -> String {
        (draft as NSString).replacingCharacters(
            in: NSRange(
                location: candidate.range.location,
                length: candidate.range.length
            ),
            with: ""
        )
    }
}
