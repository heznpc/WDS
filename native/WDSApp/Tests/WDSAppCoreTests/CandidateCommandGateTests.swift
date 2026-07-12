import XCTest
@testable import WDSAppCore

final class CandidateCommandGateTests: XCTestCase {
    func testSessionCanBeConsumedExactlyOnce() {
        let gate = CandidateCommandGate()
        let session = gate.begin()

        XCTAssertTrue(gate.hasActiveSession)
        XCTAssertTrue(gate.consume(session))
        XCTAssertFalse(gate.hasActiveSession)
        XCTAssertFalse(gate.consume(session))
    }

    func testReplacingSessionRejectsQueuedEventFromPreviousCandidate() {
        let gate = CandidateCommandGate()
        let stale = gate.begin()
        let current = gate.begin()

        XCTAssertFalse(gate.consume(stale))
        XCTAssertTrue(gate.hasActiveSession)
        XCTAssertTrue(gate.consume(current))
    }

    func testInvalidationRejectsPendingCommand() {
        let gate = CandidateCommandGate()
        let session = gate.begin()

        gate.invalidate()

        XCTAssertFalse(gate.hasActiveSession)
        XCTAssertFalse(gate.consume(session))
    }
}
