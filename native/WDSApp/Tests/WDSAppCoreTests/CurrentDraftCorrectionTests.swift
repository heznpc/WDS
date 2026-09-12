import Foundation
import XCTest
@testable import WDSAppCore

final class CurrentDraftCorrectionTests: XCTestCase {
    private let deletionOnly = CurrentDraftAnalyzer()
    private let withCorrections = CurrentDraftAnalyzer(
        maximumCandidates: 3,
        includesCorrections: true
    )

    func testCorrectionsAreOffByDefaultSoADeleteOnlyCallerCannotStripAToken() {
        for draft in ["이 파일를 열어 줘", "이거 왜 안되요"] {
            XCTAssertTrue(deletionOnly.analyze(draft).isEmpty, draft)
        }
    }

    func testParticleCorrectionCarriesItsReplacementAndAnExactRange() throws {
        let draft = "이 파일를 열어 줘"
        let candidate = try XCTUnwrap(withCorrections.analyze(draft).first)

        XCTAssertEqual(candidate.originalText, "파일를")
        XCTAssertEqual(candidate.replacementText, "파일을")
        XCTAssertTrue(candidate.isCorrection)
        XCTAssertEqual(candidate.reason, .correctedParticle)
        XCTAssertEqual(candidate.safety, .reviewRequired)
        XCTAssertEqual(candidate.range, CurrentDraftUTF16Range(
            location: ("이 " as NSString).length,
            length: ("파일를" as NSString).length
        ))
        XCTAssertEqual(applying(candidate, to: draft), "이 파일을 열어 줘")
    }

    func testSpellingCorrectionIsHighSafetyBecauseTheWrongFormHasNoReading() throws {
        let draft = "이 부분이 왜 안되요"
        let candidate = try XCTUnwrap(withCorrections.analyze(draft).first)

        XCTAssertEqual(candidate.originalText, "안되요")
        XCTAssertEqual(candidate.replacementText, "안돼요")
        XCTAssertEqual(candidate.reason, .correctedSpelling)
        XCTAssertEqual(candidate.safety, .high)
        XCTAssertEqual(applying(candidate, to: draft), "이 부분이 왜 안돼요")
    }

    func testEmotionalDeletionStillOutranksACorrectionInTheSameDraft() throws {
        let draft = "씨발, 이 파일를 다시 정리해 주세요."
        let candidates = withCorrections.analyze(draft)
        let first = try XCTUnwrap(candidates.first)

        XCTAssertEqual(first.originalText, "씨발, ")
        XCTAssertEqual(first.reason, .detachableEmotionalInterjection)
        XCTAssertFalse(first.isCorrection)
        XCTAssertTrue(candidates.contains { $0.reason == .correctedParticle })
    }

    /// The axis the product argument needs. `confidence` says how safe an edit
    /// is; this says what leaving it in costs. They rank in opposite orders, and
    /// a duplicated comma versus an opening expletive is the clearest case.
    func testInterpretiveImpactRanksOppositeToConfidence() {
        let comma = CurrentDraftDeletionCandidate(
            range: CurrentDraftUTF16Range(location: 0, length: 1),
            originalText: ",",
            reason: .duplicatePunctuation,
            confidence: 0.98,
            safety: .high
        )
        let profanity = CurrentDraftDeletionCandidate(
            range: CurrentDraftUTF16Range(location: 0, length: 3),
            originalText: "씨발 ",
            reason: .detachableEmotionalInterjection,
            confidence: 0.94,
            safety: .reviewRequired
        )

        XCTAssertGreaterThan(comma.confidence, profanity.confidence)
        XCTAssertLessThan(comma.interpretiveImpact, profanity.interpretiveImpact)
    }

    func testEveryReasonHasAnInterpretiveImpactInsideTheUnitRange() {
        let reasons: [CurrentDraftDeletionReason] = [
            .detachableEmotionalInterjection,
            .removableEmotionalIntensifier,
            .detachableConversationalOpening,
            .duplicateHesitation,
            .duplicatePunctuation,
            .correctedParticle,
            .correctedSpelling,
        ]

        for reason in reasons {
            let candidate = CurrentDraftDeletionCandidate(
                range: CurrentDraftUTF16Range(location: 0, length: 1),
                originalText: "x",
                reason: reason,
                confidence: 0.9,
                safety: .reviewRequired
            )
            XCTAssertGreaterThan(candidate.interpretiveImpact, 0, reason.rawValue)
            XCTAssertLessThanOrEqual(candidate.interpretiveImpact, 1, reason.rawValue)
        }
    }

    func testCorrectionsAreSuppressedWhenTheDraftIsAboutItsOwnWording() {
        let drafts = [
            "파일를 이라는 표현이 맞는지 봐 줘",
            "fuck을 제거해 줘",
        ]

        for draft in drafts {
            XCTAssertTrue(withCorrections.analyze(draft).isEmpty, draft)
        }
    }

    func testExpandedEmotionalVocabularyReachesBeyondOneWordFamily() throws {
        let cases = [
            ("젠장, 이 응답의 오류 원인을 다시 설명해 주세요.", "젠장, "),
            ("아휴, 이 응답의 오류 원인을 다시 설명해 주세요.", "아휴, "),
            ("fuck, please rewrite this section clearly.", "fuck, "),
        ]

        for (draft, removed) in cases {
            let candidate = try XCTUnwrap(deletionOnly.analyze(draft).first, draft)
            XCTAssertEqual(candidate.originalText, removed, draft)
            XCTAssertEqual(
                candidate.reason,
                .detachableEmotionalInterjection,
                draft
            )
        }
    }

    func testIntensifierVocabularyCoversBothLanguages() throws {
        let cases = [
            ("이 답변이 졸라 별론데 다시 작성해 줘.", "졸라 "),
            ("this answer is fucking broken, rewrite it please.", "fucking "),
        ]

        for (draft, removed) in cases {
            let candidate = try XCTUnwrap(deletionOnly.analyze(draft).first, draft)
            XCTAssertEqual(candidate.originalText, removed, draft)
            XCTAssertEqual(
                candidate.reason,
                .removableEmotionalIntensifier,
                draft
            )
        }
    }

    /// Referential forms are the object or the predicate mid-sentence, so a
    /// positional rule that removed one would delete the request itself.
    func testReferentialEmotionalFormsAreOnlyRemovableAsAWholeDraft() throws {
        for draft in ["이 코드 진짜 병신", "remove this crap"] {
            XCTAssertTrue(deletionOnly.analyze(draft).isEmpty, draft)
        }

        for draft in ["짜증나", "병신", "shit"] {
            let candidate = try XCTUnwrap(deletionOnly.analyze(draft).first, draft)
            XCTAssertEqual(candidate.originalText, draft, draft)
            XCTAssertEqual(
                candidate.reason,
                .detachableEmotionalInterjection,
                draft
            )
            XCTAssertFalse(candidate.isCorrection, draft)
        }
    }

    func testCorrectionsStayStatelessAcrossRepeatedCalls() {
        for _ in 0..<20 {
            XCTAssertEqual(
                withCorrections.analyze("이 파일를 열어 줘"),
                withCorrections.analyze("이 파일를 열어 줘")
            )
        }
    }

    private func applying(
        _ candidate: CurrentDraftDeletionCandidate,
        to draft: String
    ) -> String {
        (draft as NSString).replacingCharacters(
            in: NSRange(
                location: candidate.range.location,
                length: candidate.range.length
            ),
            with: candidate.replacementText
        )
    }
}
