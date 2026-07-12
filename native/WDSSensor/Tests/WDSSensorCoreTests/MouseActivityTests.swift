import Testing
@testable import WDSSensorCore

@Test func ringEnforcesCapacity() {
    var ring = MouseActivityRing(capacity: 3, windowMilliseconds: 10_000)
    for index in 0..<4 {
        ring.append(
            MouseSample(
                timestampMilliseconds: Double(index),
                kind: .click
            )
        )
    }

    let summary = ring.summary(nowMilliseconds: 4)
    #expect(ring.count == 3)
    #expect(summary.eventCount == 3)
    #expect(summary.clickCount == 3)
}

@Test func ringPrunesOutsideWindow() {
    var ring = MouseActivityRing(capacity: 20, windowMilliseconds: 1_000)
    ring.append(MouseSample(timestampMilliseconds: 0, kind: .click))
    ring.append(MouseSample(timestampMilliseconds: 500, kind: .click))
    ring.append(MouseSample(timestampMilliseconds: 1_500, kind: .click))

    let summary = ring.summary(nowMilliseconds: 1_600)
    #expect(summary.eventCount == 1)
    #expect(summary.clickCount == 1)
}

@Test func summaryDerivesDistanceSpeedAndDirection() {
    var ring = MouseActivityRing(capacity: 20, windowMilliseconds: 5_000)
    ring.append(MouseSample(timestampMilliseconds: 0, kind: .move, x: 0, y: 0))
    ring.append(MouseSample(timestampMilliseconds: 1_000, kind: .move, x: 3, y: 4))

    let summary = ring.summary(nowMilliseconds: 1_000)
    #expect(summary.distancePoints == 5)
    #expect(summary.averageSpeedPointsPerSecond == 5)
    #expect(summary.direction == "southeast")
    #expect(summary.movementCount == 2)
}

@Test func summaryAggregatesClickAndScrollWithoutRawCoordinates() {
    var ring = MouseActivityRing(capacity: 20, windowMilliseconds: 5_000)
    ring.append(MouseSample(timestampMilliseconds: 0, kind: .click))
    ring.append(MouseSample(timestampMilliseconds: 10, kind: .click))
    ring.append(
        MouseSample(
            timestampMilliseconds: 20,
            kind: .scroll,
            scrollX: 2,
            scrollY: -4
        )
    )

    let summary = ring.summary(nowMilliseconds: 20)
    #expect(summary.clickCount == 2)
    #expect(summary.scrollEventCount == 1)
    #expect(summary.scrollX == 2)
    #expect(summary.scrollY == -4)
    #expect(summary.direction == "stationary")
}

@Test func clearingRingRemovesAllRecentActivity() {
    var ring = MouseActivityRing(capacity: 20, windowMilliseconds: 5_000)
    ring.append(MouseSample(timestampMilliseconds: 10, kind: .move, x: 1, y: 2))
    ring.append(MouseSample(timestampMilliseconds: 20, kind: .click))

    ring.removeAll()

    let summary = ring.summary(nowMilliseconds: 20)
    #expect(ring.count == 0)
    #expect(summary.eventCount == 0)
    #expect(summary.clickCount == 0)
    #expect(summary.distancePoints == 0)
}

@Test func stopGateAllowsExactlyOneTerminalTransition() {
    var gate = SensorStopGate()

    let first = gate.beginStopping()
    let second = gate.beginStopping()
    let third = gate.beginStopping()

    #expect(first)
    #expect(gate.isStopped)
    #expect(!second)
    #expect(!third)
}
