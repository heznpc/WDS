import XCTest
@testable import WDSAppCore

final class CandidateHotKeyLifecycleTests: XCTestCase {
    private func identity(
        _ phrase: String = "씨발",
        processIdentifier: Int32 = 4_242
    ) -> CurrentDraftCandidateIdentity {
        CurrentDraftCandidateIdentity(
            bundleIdentifier: "com.example.chat",
            processIdentifier: processIdentifier,
            focusEpoch: 7,
            range: CurrentDraftUTF16Range(location: 0, length: (phrase as NSString).length),
            originalText: phrase
        )
    }

    func testShowingWithRegistrationAdvertisesTheShortcuts() {
        var lifecycle = CandidateHotKeyLifecycle()
        let candidate = identity()

        lifecycle.didShow(candidate, hotKeysRegistered: true)

        XCTAssertTrue(lifecycle.isShowing)
        XCTAssertEqual(lifecycle.shownIdentity, candidate)
        XCTAssertTrue(lifecycle.keyboardShortcutsAvailable)
        XCTAssertFalse(lifecycle.hasOrphanedRegistration)
    }

    func testPanelStillShowsWhenHotKeyRegistrationFailed() {
        var lifecycle = CandidateHotKeyLifecycle()
        let candidate = identity()

        lifecycle.didShow(candidate, hotKeysRegistered: false)

        XCTAssertTrue(lifecycle.isShowing)
        XCTAssertFalse(lifecycle.keyboardShortcutsAvailable)
        XCTAssertFalse(lifecycle.hasOrphanedRegistration)
        XCTAssertTrue(lifecycle.acceptsCommand(for: candidate))
    }

    func testHidingReleasesBothThePanelAndTheRegistration() {
        var lifecycle = CandidateHotKeyLifecycle()
        let candidate = identity()
        lifecycle.didShow(candidate, hotKeysRegistered: true)

        lifecycle.didHide()

        XCTAssertFalse(lifecycle.isShowing)
        XCTAssertNil(lifecycle.shownIdentity)
        XCTAssertFalse(lifecycle.keyboardShortcutsAvailable)
        XCTAssertFalse(lifecycle.hasOrphanedRegistration)
        XCTAssertFalse(lifecycle.acceptsCommand(for: candidate))
    }

    func testHidingWhenNothingIsShownIsSafe() {
        var lifecycle = CandidateHotKeyLifecycle()

        lifecycle.didHide()
        lifecycle.didHide()

        XCTAssertFalse(lifecycle.isShowing)
        XCTAssertFalse(lifecycle.hasOrphanedRegistration)
        XCTAssertEqual(lifecycle, CandidateHotKeyLifecycle())
    }

    func testReplacingTheCandidateMovesTheRegistrationWithThePanel() {
        var lifecycle = CandidateHotKeyLifecycle()
        let first = identity("씨발")
        let second = identity("존나")
        lifecycle.didShow(first, hotKeysRegistered: true)

        lifecycle.didShow(second, hotKeysRegistered: true)

        XCTAssertEqual(lifecycle.shownIdentity, second)
        XCTAssertTrue(lifecycle.keyboardShortcutsAvailable)
        XCTAssertFalse(lifecycle.hasOrphanedRegistration)
        XCTAssertFalse(lifecycle.acceptsCommand(for: first))
        XCTAssertTrue(lifecycle.acceptsCommand(for: second))
    }

    func testCommandForAnotherProcessIsRefused() {
        var lifecycle = CandidateHotKeyLifecycle()
        lifecycle.didShow(identity(processIdentifier: 1), hotKeysRegistered: true)

        XCTAssertFalse(
            lifecycle.acceptsCommand(for: identity(processIdentifier: 2))
        )
    }

    /// A registered hot key must never outlive the panel it belongs to, or
    /// `⌃⌘⌫` could delete a span the user can no longer see.
    func testNoSequenceLeavesAnOrphanedRegistration() {
        let candidates = [identity("씨발"), identity("존나")]
        let registrations = [true, false]
        var lifecycle = CandidateHotKeyLifecycle()

        for candidate in candidates {
            for registered in registrations {
                lifecycle.didShow(candidate, hotKeysRegistered: registered)
                XCTAssertFalse(lifecycle.hasOrphanedRegistration)
                XCTAssertEqual(
                    lifecycle.keyboardShortcutsAvailable,
                    registered,
                    "shortcuts must reflect the reported registration result"
                )

                lifecycle.didHide()
                XCTAssertFalse(lifecycle.hasOrphanedRegistration)
                XCTAssertFalse(lifecycle.isShowing)
            }
        }
    }
}
