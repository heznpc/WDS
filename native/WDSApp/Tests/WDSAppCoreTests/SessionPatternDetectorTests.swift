import Foundation
import XCTest
@testable import WDSAppCore

final class SessionPatternDetectorTests: XCTestCase {
    func testCommaCandidateRequiresTwoDistinctContextsAndMatchesFullwidthComma() {
        let detector = SessionPatternDetector()

        detector.observeCompletedDraft("그러니까, 첫 번째 결론입니다.")
        XCTAssertNil(detector.suggestion(forCurrentDraft: "그러니까, 아직 이릅니다."))

        detector.observeCompletedDraft("그러니까，두 번째 관찰입니다.")
        let current = "그러니까, 지금 문장을 씁니다."
        let suggestion = detector.suggestion(forCurrentDraft: current)

        XCTAssertEqual(suggestion?.displayPhrase, "그러니까,")
        XCTAssertEqual(suggestion?.exactDeleteText, "그러니까, ")
        XCTAssertEqual(suggestion?.range, SessionPatternTextRange(
            location: 0,
            length: ("그러니까, " as NSString).length
        ))
        XCTAssertEqual(suggestion?.observationCount, 2)
        XCTAssertEqual(suggestion?.distinctContextCount, 2)
        XCTAssertEqual(detector.summary.readyCandidateCount, 1)
    }

    func testPlainCandidateRequiresThreeObservationsAndChoosesThreeTokenPhrase() {
        let detector = SessionPatternDetector()

        detector.observeCompletedDraft("To be honest the first answer changed")
        detector.observeCompletedDraft("To be honest another route appeared")
        XCTAssertNil(detector.suggestion(forCurrentDraft: "To be honest this is too early"))

        detector.observeCompletedDraft("To be honest we found a third context")
        let suggestion = detector.suggestion(forCurrentDraft: "To be honest this can now appear")

        XCTAssertEqual(suggestion?.displayPhrase, "To be honest")
        XCTAssertEqual(suggestion?.exactDeleteText, "To be honest ")
        XCTAssertEqual(suggestion?.range.length, ("To be honest " as NSString).length)
        XCTAssertEqual(suggestion?.observationCount, 3)
        XCTAssertEqual(suggestion?.distinctContextCount, 3)
    }

    func testRepeatedIdenticalSuffixNeverMakesCandidateReady() {
        let detector = SessionPatternDetector()
        for _ in 0..<5 {
            detector.observeCompletedDraft("Well, exactly the same suffix")
        }

        XCTAssertNil(detector.suggestion(forCurrentDraft: "Well, a new current suffix"))
        XCTAssertEqual(detector.summary.readyCandidateCount, 0)
        XCTAssertEqual(detector.summary.distinctContextCount, 1)
        XCTAssertEqual(detector.summary.duplicateContextObservationCount, 4)
    }

    func testCodeQuotesURLsCommandsAndListsAreExcluded() {
        let detector = SessionPatternDetector()
        let excludedDrafts = [
            "```swift, print(1)",
            "    indented code, still code",
            "> quoted, statement",
            "\"quoted, statement\"",
            "https://example.com, path",
            "/rewrite, this",
            "$ git status, now",
            "user@host % git status now",
            "let value = first result",
            "- list, item",
            "– list, item",
            "1. ordered, item",
            "[ ] task, item",
            "## heading, item",
        ]

        excludedDrafts.forEach(detector.observeCompletedDraft)

        XCTAssertEqual(detector.summary.observedDraftCount, excludedDrafts.count)
        XCTAssertEqual(detector.summary.eligibleDraftCount, 0)
        XCTAssertEqual(detector.summary.retainedCandidateCount, 0)
    }

    func testEmojiSuggestionUsesUTF16Range() {
        let detector = SessionPatternDetector()
        detector.observeCompletedDraft("🤔, 첫 맥락")
        detector.observeCompletedDraft("🤔, second context")

        let current = "🤔, 새로운 맥락"
        let suggestion = detector.suggestion(forCurrentDraft: current)
        let expectedText = "🤔, "

        XCTAssertEqual(suggestion?.displayPhrase, "🤔,")
        XCTAssertEqual(suggestion?.exactDeleteText, expectedText)
        XCTAssertEqual(suggestion?.range.location, 0)
        XCTAssertEqual(suggestion?.range.length, (expectedText as NSString).length)
        XCTAssertNotEqual(expectedText.count, (expectedText as NSString).length)
    }

    func testCommaBoundaryRespects24CharacterLimit() {
        let allowed = SessionPatternDetector()
        allowed.observeCompletedDraft("abcdefghijklmnopqrstuvw, first")
        allowed.observeCompletedDraft("abcdefghijklmnopqrstuvw, second")
        XCTAssertNotNil(allowed.suggestion(
            forCurrentDraft: "abcdefghijklmnopqrstuvw, current"
        ))

        let tooLong = SessionPatternDetector()
        tooLong.observeCompletedDraft("abcdefghijklmnopqrstuvwx, first")
        tooLong.observeCompletedDraft("abcdefghijklmnopqrstuvwx, second")
        tooLong.observeCompletedDraft("abcdefghijklmnopqrstuvwx, third")
        XCTAssertEqual(tooLong.summary.retainedCandidateCount, 0)
    }

    func testCombiningMarksCannotBypassShortDisplayLimit() {
        let detector = SessionPatternDetector()
        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 1_000)
        detector.observeCompletedDraft("\(oversizedGrapheme), first context")
        detector.observeCompletedDraft("\(oversizedGrapheme), second context")

        XCTAssertEqual(detector.summary.retainedCandidateCount, 0)
        XCTAssertNil(detector.suggestion(
            forCurrentDraft: "\(oversizedGrapheme), current context"
        ))
    }

    func testOnlyOpeningFromFirstLineIsCandidateWhileFullSuffixDrivesDiversity() {
        let detector = SessionPatternDetector()
        detector.observeCompletedDraft("잠깐,\n첫 번째 본문")
        detector.observeCompletedDraft("잠깐,\n두 번째 본문")

        XCTAssertNotNil(detector.suggestion(forCurrentDraft: "잠깐,\n현재 본문"))
        XCTAssertNil(detector.suggestion(forCurrentDraft: "현재 본문\n잠깐, 뒤쪽 문장"))
    }

    func testResetClearsSessionAndSerializedMemoryContainsNoDraftOrSuffix() throws {
        let detector = SessionPatternDetector()
        let firstDraft = "요컨대, PRIVATE_SUFFIX_ALPHA_82e9"
        let secondDraft = "요컨대, PRIVATE_SUFFIX_BETA_19d4"
        detector.observeCompletedDraft(firstDraft)
        detector.observeCompletedDraft(secondDraft)

        let snapshot = try XCTUnwrap(String(
            data: detector._privacySnapshotDataForTesting(),
            encoding: .utf8
        ))
        XCTAssertTrue(snapshot.contains("요컨대,"))
        XCTAssertFalse(snapshot.contains(firstDraft))
        XCTAssertFalse(snapshot.contains(secondDraft))
        XCTAssertFalse(snapshot.contains("PRIVATE_SUFFIX_ALPHA_82e9"))
        XCTAssertFalse(snapshot.contains("PRIVATE_SUFFIX_BETA_19d4"))
        XCTAssertFalse(snapshot.contains("draft"))
        XCTAssertFalse(snapshot.contains("suffix"))

        detector.reset()

        XCTAssertEqual(detector.summary, SessionPatternSummary(
            observedDraftCount: 0,
            eligibleDraftCount: 0,
            retainedCandidateCount: 0,
            readyCandidateCount: 0,
            distinctContextCount: 0,
            duplicateContextObservationCount: 0
        ))
        XCTAssertNil(detector.suggestion(forCurrentDraft: "요컨대, 새로운 문장"))
        let resetSnapshot = try XCTUnwrap(String(
            data: detector._privacySnapshotDataForTesting(),
            encoding: .utf8
        ))
        XCTAssertFalse(resetSnapshot.contains("요컨대,"))
    }

    func testContextDigestsAreSaltedPerSession() throws {
        let first = SessionPatternDetector()
        let second = SessionPatternDetector()
        let draft = "In short, identical private remainder"
        first.observeCompletedDraft(draft)
        second.observeCompletedDraft(draft)

        let firstDigest = try XCTUnwrap(contextDigests(in: first).first)
        let secondDigest = try XCTUnwrap(contextDigests(in: second).first)

        XCTAssertNotEqual(firstDigest, secondDigest)
        XCTAssertEqual(firstDigest.count, 64)
        XCTAssertTrue(firstDigest.allSatisfy { $0.isHexDigit })
    }

    private func contextDigests(in detector: SessionPatternDetector) throws -> [String] {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: detector._privacySnapshotDataForTesting()
            ) as? [String: Any]
        )
        let candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        let candidate = try XCTUnwrap(candidates.first)
        return try XCTUnwrap(candidate["contextDigests"] as? [String])
    }
}
