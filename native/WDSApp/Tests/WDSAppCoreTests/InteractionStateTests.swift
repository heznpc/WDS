import XCTest
@testable import WDSAppCore

final class InteractionStateTests: XCTestCase {
    func testBeginsOneMutuallyExclusiveInteraction() throws {
        var state = InteractionState()

        let token = try XCTUnwrap(state.begin(.candidateInspection))

        XCTAssertEqual(state.phase, .inspectingCandidate(token))
        XCTAssertTrue(state.isActive(.candidateInspection))
        XCTAssertFalse(state.isIdle)
        XCTAssertNil(state.begin(.preview))
    }

    func testOnlyOwningTokenCanFinishInteraction() throws {
        var state = InteractionState()
        let stale = try XCTUnwrap(state.begin(.preview))
        XCTAssertTrue(state.finish(stale))
        let current = try XCTUnwrap(state.begin(.preview))

        XCTAssertFalse(state.finish(stale))
        XCTAssertTrue(state.owns(current))
        XCTAssertEqual(state.phase, .previewing(current))
        XCTAssertTrue(state.finish(current))
        XCTAssertTrue(state.isIdle)
    }

    func testCancelledCandidateCallbackCannotCompleteReplacementInteraction() throws {
        var state = InteractionState()
        let candidate = try XCTUnwrap(state.begin(.candidateInspection))

        XCTAssertTrue(state.cancel(.candidateInspection))
        let deletion = try XCTUnwrap(state.begin(.delete))

        XCTAssertFalse(state.finish(candidate))
        XCTAssertTrue(state.owns(deletion))
        XCTAssertEqual(state.phase, .deleting(deletion))
    }

    func testCancellingDifferentOperationDoesNotChangeState() throws {
        var state = InteractionState()
        let overlay = try XCTUnwrap(state.begin(.overlay))

        XCTAssertFalse(state.cancel(.delete))
        XCTAssertTrue(state.owns(overlay))
        XCTAssertEqual(state.phase, .renderingOverlay(overlay))
    }

    func testCancelAllReturnsToIdle() throws {
        var state = InteractionState()
        _ = try XCTUnwrap(state.begin(.delete))

        state.cancelAll()

        XCTAssertTrue(state.isIdle)
        XCTAssertNil(state.phase.operation)
    }
}
