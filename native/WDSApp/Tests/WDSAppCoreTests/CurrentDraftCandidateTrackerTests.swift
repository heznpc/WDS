import XCTest
@testable import WDSAppCore

final class CurrentDraftCandidateTrackerTests: XCTestCase {
    private let analyzer = CurrentDraftAnalyzer(maximumCandidates: 1)

    /// A draft the analyzer proposes a removal for.
    private func draft(
        _ text: String = "씨발 이 파서의 널 체크를 고쳐줘",
        bundleIdentifier: String = "com.example.chat",
        processIdentifier: Int32 = 4_242,
        focusEpoch: Int = 7
    ) -> CurrentDraftSnapshot {
        CurrentDraftSnapshot(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            focusEpoch: focusEpoch,
            text: text
        )
    }

    /// A draft with no emotional noise, so the analyzer returns nothing.
    private func cleanDraft() -> CurrentDraftSnapshot {
        draft("이 파서의 널 체크를 고쳐줘")
    }

    private func identity(
        in snapshot: CurrentDraftSnapshot
    ) throws -> CurrentDraftCandidateIdentity {
        try XCTUnwrap(
            CurrentDraftCandidateTracker.candidateState(
                for: snapshot,
                analyzer: analyzer
            )
        ).identity
    }

    // MARK: - Derivation

    func testDerivedRangeLiterallySpellsThePhraseInThatDraft() throws {
        let snapshot = draft()

        let state = try XCTUnwrap(
            CurrentDraftCandidateTracker.candidateState(
                for: snapshot,
                analyzer: analyzer
            )
        )

        let source = snapshot.text as NSString
        let range = NSRange(
            location: state.identity.range.location,
            length: state.identity.range.length
        )
        XCTAssertLessThanOrEqual(NSMaxRange(range), source.length)
        XCTAssertEqual(source.substring(with: range), state.identity.originalText)
        XCTAssertEqual(state.displayPhrase, "씨발")
    }

    func testCleanDraftYieldsNoCandidate() {
        XCTAssertNil(
            CurrentDraftCandidateTracker.candidateState(
                for: cleanDraft(),
                analyzer: analyzer
            )
        )
    }

    func testSameTextInAnotherProcessIsADifferentCandidate() throws {
        let here = try identity(in: draft(processIdentifier: 1))
        let there = try identity(in: draft(processIdentifier: 2))

        XCTAssertNotEqual(here, there)
    }

    func testSameTextAfterFocusMovedIsADifferentCandidate() throws {
        let before = try identity(in: draft(focusEpoch: 1))
        let after = try identity(in: draft(focusEpoch: 2))

        XCTAssertNotEqual(before, after)
    }

    // MARK: - Draft updates

    func testNewCandidateIsReadyToInspect() throws {
        var tracker = CurrentDraftCandidateTracker()

        let outcome = tracker.refresh(
            with: draft(),
            analyzer: analyzer,
            isPanelVisible: false
        )

        guard case .readyToInspect(let state) = outcome else {
            return XCTFail("expected readyToInspect, got \(outcome)")
        }
        XCTAssertEqual(state.identity, try identity(in: draft()))
        XCTAssertEqual(tracker.state?.identity, state.identity)
    }

    func testDisappearingDraftClearsTheCandidate() {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)

        let outcome = tracker.refresh(
            with: nil,
            analyzer: analyzer,
            isPanelVisible: false
        )

        XCTAssertEqual(outcome, .cleared)
        XCTAssertNil(tracker.state)
    }

    func testDraftLosingItsCandidateClearsTheCandidate() {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)

        let outcome = tracker.refresh(
            with: cleanDraft(),
            analyzer: analyzer,
            isPanelVisible: false
        )

        XCTAssertEqual(outcome, .cleared)
        XCTAssertNil(tracker.state)
    }

    func testUnchangedDraftDoesNotRePromptWhilePanelIsHidden() {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)

        let outcome = tracker.refresh(
            with: draft(),
            analyzer: analyzer,
            isPanelVisible: false
        )

        XCTAssertEqual(outcome, .unchanged)
    }

    func testContinuedTypingHidesTheVisiblePanelForThatCandidate() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())

        let outcome = tracker.refresh(
            with: draft(),
            analyzer: analyzer,
            isPanelVisible: true
        )

        guard case .hiddenWhileTyping = outcome else {
            return XCTFail("expected hiddenWhileTyping, got \(outcome)")
        }
        XCTAssertTrue(tracker.isHiddenWhileTyping(live))
        XCTAssertFalse(tracker.isActionable(live))
    }

    func testADifferentCandidateClearsTheTypingDismissalOfThePreviousOne() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: true)
        let hidden = try identity(in: draft())
        XCTAssertTrue(tracker.isHiddenWhileTyping(hidden))

        let next = draft("존나 구려 이 파서 코드 좀 고쳐줘")
        let outcome = tracker.refresh(
            with: next,
            analyzer: analyzer,
            isPanelVisible: false
        )

        guard case .readyToInspect = outcome else {
            return XCTFail("expected readyToInspect, got \(outcome)")
        }
        XCTAssertFalse(tracker.isHiddenWhileTyping(try identity(in: next)))
    }

    // MARK: - Debounce

    func testNewerTicketRetiresTheOlderTimerForTheSameCandidate() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())

        let stale = try XCTUnwrap(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: true)
        )
        let current = try XCTUnwrap(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: true)
        )

        XCTAssertFalse(tracker.canBeginInspection(stale))
        XCTAssertTrue(tracker.canBeginInspection(current))
    }

    func testTicketCanStartInspectionExactlyOnce() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())
        let ticket = try XCTUnwrap(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: true)
        )

        XCTAssertTrue(tracker.beginInspection(ticket))

        XCTAssertFalse(tracker.hasPendingInspection)
        XCTAssertFalse(tracker.beginInspection(ticket))
    }

    func testTimerForAReplacedCandidateIsRefused() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())
        let ticket = try XCTUnwrap(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: true)
        )

        _ = tracker.refresh(
            with: draft("존나 구려 이 파서 코드 좀 고쳐줘"),
            analyzer: analyzer,
            isPanelVisible: false
        )

        XCTAssertFalse(tracker.canBeginInspection(ticket))
    }

    func testNoInspectionIsArmedWhileEngineIsOffOrBusy() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())

        XCTAssertNil(
            tracker.scheduleInspection(for: live, engineEnabled: false, isIdle: true)
        )
        XCTAssertNil(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: false)
        )
        XCTAssertFalse(tracker.hasPendingInspection)
    }

    func testKeptCandidateIsNeverRescheduled() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())
        XCTAssertTrue(tracker.keep(live))

        XCTAssertNil(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: true)
        )
    }

    func testCancellingPendingInspectionKeepsTheCandidate() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())
        let ticket = try XCTUnwrap(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: true)
        )

        tracker.cancelPendingInspection()

        XCTAssertFalse(tracker.canBeginInspection(ticket))
        XCTAssertEqual(tracker.state?.identity, live)
    }

    // MARK: - Resume and reshow

    func testResumeIsRefusedWhileThePanelIsAlreadyUp() {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)

        XCTAssertNil(
            tracker.resumeInspection(
                isPanelVisible: true,
                engineEnabled: true,
                isIdle: true
            )
        )
    }

    func testResumeReOffersTheHiddenCandidate() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)

        let ticket = try XCTUnwrap(
            tracker.resumeInspection(
                isPanelVisible: false,
                engineEnabled: true,
                isIdle: true
            )
        )

        XCTAssertEqual(ticket.identity, try identity(in: draft()))
        XCTAssertTrue(tracker.canBeginInspection(ticket))
    }

    func testReshowClearsTypingDismissalButNotAnExplicitKeep() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: true)
        let live = try identity(in: draft())
        XCTAssertFalse(tracker.isActionable(live))

        let ticket = try XCTUnwrap(
            tracker.reshowInspection(engineEnabled: true, isIdle: true)
        )
        XCTAssertEqual(ticket.identity, live)
        XCTAssertTrue(tracker.isActionable(live))

        XCTAssertTrue(tracker.keep(live))
        XCTAssertNil(tracker.reshowInspection(engineEnabled: true, isIdle: true))
    }

    // MARK: - Re-verification

    func testResultIsPresentedOnlyWhileTheDraftStillYieldsTheSameCandidate() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())
        let ticket = try XCTUnwrap(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: true)
        )
        tracker.beginInspection(ticket)

        XCTAssertTrue(
            tracker.canPresent(
                ticket,
                latestSnapshot: draft(),
                analyzer: analyzer
            )
        )
        XCTAssertFalse(
            tracker.canPresent(ticket, latestSnapshot: nil, analyzer: analyzer)
        )
        XCTAssertFalse(
            tracker.canPresent(
                ticket,
                latestSnapshot: cleanDraft(),
                analyzer: analyzer
            )
        )
        XCTAssertFalse(
            tracker.canPresent(
                ticket,
                latestSnapshot: draft(processIdentifier: 9_999),
                analyzer: analyzer
            )
        )
    }

    func testResultIsNotPresentedAfterTheUserKeptTheCandidate() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())
        let ticket = try XCTUnwrap(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: true)
        )
        tracker.beginInspection(ticket)

        XCTAssertTrue(tracker.keep(live))

        XCTAssertFalse(
            tracker.canPresent(
                ticket,
                latestSnapshot: draft(),
                analyzer: analyzer
            )
        )
    }

    func testApprovalProceedsOnlyOnAnUnchangedDraft() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())

        guard case .proceed(let state) = tracker.approval(
            of: live,
            latestSnapshot: draft(),
            analyzer: analyzer,
            engineEnabled: true,
            isIdle: true
        ) else { return XCTFail("expected proceed") }
        XCTAssertEqual(state.identity, live)

        XCTAssertEqual(
            tracker.approval(
                of: live,
                latestSnapshot: draft("이 파서의 널 체크를 고쳐줘 부탁해"),
                analyzer: analyzer,
                engineEnabled: true,
                isIdle: true
            ),
            .stale
        )
        XCTAssertEqual(
            tracker.approval(
                of: live,
                latestSnapshot: nil,
                analyzer: analyzer,
                engineEnabled: true,
                isIdle: true
            ),
            .stale
        )
    }

    func testApprovalIsRefusedWhileEngineIsOffOrBusy() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())

        XCTAssertEqual(
            tracker.approval(
                of: live,
                latestSnapshot: draft(),
                analyzer: analyzer,
                engineEnabled: false,
                isIdle: true
            ),
            .stale
        )
        XCTAssertEqual(
            tracker.approval(
                of: live,
                latestSnapshot: draft(),
                analyzer: analyzer,
                engineEnabled: true,
                isIdle: false
            ),
            .stale
        )
    }

    /// The delete path re-checks the draft while it already owns the
    /// interaction, so the re-derivation must not itself require idleness.
    func testDraftReCheckStillWorksWhileADeleteIsInFlight() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())

        XCTAssertNotNil(
            tracker.stillMatches(
                live,
                latestSnapshot: draft(),
                analyzer: analyzer
            )
        )
        XCTAssertNil(
            tracker.stillMatches(
                live,
                latestSnapshot: draft(processIdentifier: 9_999),
                analyzer: analyzer
            )
        )
        XCTAssertNil(
            tracker.stillMatches(live, latestSnapshot: nil, analyzer: analyzer)
        )
    }

    // MARK: - User decisions and lifetime

    func testKeepIsRefusedForACandidateThatIsNoLongerCurrent() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let stale = try identity(in: draft())
        _ = tracker.refresh(
            with: draft("존나 구려 이 파서 코드 좀 고쳐줘"),
            analyzer: analyzer,
            isPanelVisible: false
        )

        XCTAssertFalse(tracker.keep(stale))
        XCTAssertFalse(tracker.isKept(stale))
    }

    func testKeepSuppressesOnlyThatExactCandidate() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let kept = try identity(in: draft())
        XCTAssertTrue(tracker.keep(kept))

        let outcome = tracker.refresh(
            with: draft(),
            analyzer: analyzer,
            isPanelVisible: false
        )
        XCTAssertEqual(outcome, .unchanged)

        _ = tracker.refresh(with: cleanDraft(), analyzer: analyzer, isPanelVisible: false)
        let reappeared = tracker.refresh(
            with: draft(),
            analyzer: analyzer,
            isPanelVisible: false
        )
        guard case .alreadyKept = reappeared else {
            return XCTFail("expected alreadyKept, got \(reappeared)")
        }

        let other = draft("존나 구려 이 파서 코드 좀 고쳐줘")
        guard case .readyToInspect = tracker.refresh(
            with: other,
            analyzer: analyzer,
            isPanelVisible: false
        ) else { return XCTFail("a different candidate must still be offered") }
    }

    func testResetReleasesTheCandidateAndEveryDecisionAboutIt() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let live = try identity(in: draft())
        let ticket = try XCTUnwrap(
            tracker.scheduleInspection(for: live, engineEnabled: true, isIdle: true)
        )
        XCTAssertTrue(tracker.keep(live))

        tracker.reset()

        XCTAssertNil(tracker.state)
        XCTAssertFalse(tracker.isKept(live))
        XCTAssertFalse(tracker.isHiddenWhileTyping(live))
        XCTAssertFalse(tracker.hasPendingInspection)
        XCTAssertFalse(tracker.canBeginInspection(ticket))
    }

    /// Reset must not rewind the generation counter. If it did, a timer armed
    /// before the draft was released could match the next ticket issued after
    /// it and inspect a candidate from a dead scope.
    func testTicketFromBeforeAResetNeverMatchesALaterOne() throws {
        var tracker = CurrentDraftCandidateTracker()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let before = try identity(in: draft())
        let stale = try XCTUnwrap(
            tracker.scheduleInspection(for: before, engineEnabled: true, isIdle: true)
        )

        tracker.reset()
        _ = tracker.refresh(with: draft(), analyzer: analyzer, isPanelVisible: false)
        let reissued = try XCTUnwrap(
            tracker.scheduleInspection(for: before, engineEnabled: true, isIdle: true)
        )

        XCTAssertNotEqual(stale, reissued)
        XCTAssertFalse(tracker.canBeginInspection(stale))
        XCTAssertTrue(tracker.canBeginInspection(reissued))
    }

    func testDebounceDelaysAreTheDocumentedQuietPeriods() {
        XCTAssertEqual(CurrentDraftCandidateTracker.typingDebounce, 0.4)
        XCTAssertEqual(CurrentDraftCandidateTracker.resumeDebounce, 0.2)
    }
}
