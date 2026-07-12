public struct SensorStopGate: Sendable {
    public private(set) var isStopped = false

    public init() {}

    /// Returns true exactly once, allowing teardown and the terminal JSON line to
    /// be emitted by a single stop path even if multiple callbacks race to stop.
    public mutating func beginStopping() -> Bool {
        guard !isStopped else { return false }
        isStopped = true
        return true
    }
}
