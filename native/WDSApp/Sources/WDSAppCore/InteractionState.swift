import Foundation

/// The mutually exclusive asynchronous operations coordinated by WDSApp.
public enum InteractionOperation: Equatable, Hashable, Sendable {
    case candidateInspection
    case preview
    case delete
    case overlay
}

/// Ownership token for one asynchronous interaction.
///
/// Callbacks must present the token they received when the operation began.
/// This prevents a delayed callback from completing a newer interaction of
/// the same kind.
public struct InteractionToken: Equatable, Hashable, Sendable {
    public let operation: InteractionOperation
    fileprivate let identifier: UUID

    fileprivate init(operation: InteractionOperation, identifier: UUID = UUID()) {
        self.operation = operation
        self.identifier = identifier
    }
}

/// The single active interaction owned by the app coordinator.
public enum InteractionPhase: Equatable, Sendable {
    case idle
    case inspectingCandidate(InteractionToken)
    case previewing(InteractionToken)
    case deleting(InteractionToken)
    case renderingOverlay(InteractionToken)

    public var operation: InteractionOperation? {
        switch self {
        case .idle:
            return nil
        case .inspectingCandidate:
            return .candidateInspection
        case .previewing:
            return .preview
        case .deleting:
            return .delete
        case .renderingOverlay:
            return .overlay
        }
    }

    fileprivate var token: InteractionToken? {
        switch self {
        case .idle:
            return nil
        case .inspectingCandidate(let token),
             .previewing(let token),
             .deleting(let token),
             .renderingOverlay(let token):
            return token
        }
    }
}

/// Small, value-typed state machine for mutually exclusive app interactions.
public struct InteractionState: Equatable, Sendable {
    public private(set) var phase: InteractionPhase

    public init() {
        phase = .idle
    }

    public var isIdle: Bool {
        phase == .idle
    }

    public func isActive(_ operation: InteractionOperation) -> Bool {
        phase.operation == operation
    }

    /// Begins an operation only while idle and returns its callback ownership token.
    public mutating func begin(_ operation: InteractionOperation) -> InteractionToken? {
        guard isIdle else { return nil }
        let token = InteractionToken(operation: operation)
        switch operation {
        case .candidateInspection:
            phase = .inspectingCandidate(token)
        case .preview:
            phase = .previewing(token)
        case .delete:
            phase = .deleting(token)
        case .overlay:
            phase = .renderingOverlay(token)
        }
        return token
    }

    /// Returns whether this state still owns the exact asynchronous interaction.
    public func owns(_ token: InteractionToken) -> Bool {
        phase.token == token
    }

    /// Completes only the exact interaction represented by `token`.
    @discardableResult
    public mutating func finish(_ token: InteractionToken) -> Bool {
        guard owns(token) else { return false }
        phase = .idle
        return true
    }

    /// Cancels the active interaction only when it has the requested kind.
    @discardableResult
    public mutating func cancel(_ operation: InteractionOperation) -> Bool {
        guard isActive(operation) else { return false }
        phase = .idle
        return true
    }

    public mutating func cancelAll() {
        phase = .idle
    }
}
