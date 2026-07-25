import Foundation

public enum CandidateCommand: Equatable, Sendable {
    case approve
    case keep
    case replace
}

public struct CandidateCommandSession: Equatable, Hashable, Sendable {
    fileprivate let identifier: UUID

    fileprivate init(identifier: UUID = UUID()) {
        self.identifier = identifier
    }
}

/// One-shot command gate used by the global hot-key bridge.
///
/// A Carbon event can arrive after a candidate was replaced. Binding every
/// registration to a unique session prevents a queued event for candidate A
/// from approving candidate B.
public final class CandidateCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSession: CandidateCommandSession?

    public init() {}

    @discardableResult
    public func begin() -> CandidateCommandSession {
        let session = CandidateCommandSession()
        lock.lock()
        activeSession = session
        lock.unlock()
        return session
    }

    public func consume(_ session: CandidateCommandSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeSession == session else { return false }
        activeSession = nil
        return true
    }

    public func invalidate() {
        lock.lock()
        activeSession = nil
        lock.unlock()
    }

    public var hasActiveSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSession != nil
    }
}
