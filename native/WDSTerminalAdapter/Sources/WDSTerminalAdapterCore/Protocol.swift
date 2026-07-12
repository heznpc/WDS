import Foundation

public let wdsTerminalProtocolVersion = 1
public let wdsMaximumTerminalBufferBytes = 1_048_576
public let wdsMaximumWireMessageBytes = 1_100_000

public enum TerminalSurfaceKind: String, Codable, Equatable, Sendable {
    case zshZLE = "zsh_zle"
    case interactiveCLI = "interactive_cli"
}

public struct TerminalSurface: Codable, Equatable, Sendable {
    public let kind: TerminalSurfaceKind
    public let identifier: String?

    public init(kind: TerminalSurfaceKind, identifier: String? = nil) {
        self.kind = kind
        self.identifier = identifier
    }
}

public struct TerminalBufferSnapshot: Codable, Equatable, Sendable {
    public let buffer: String
    public let bufferSHA256: String
    public let cursorUnicodeScalarOffset: Int

    public init(buffer: String, cursorUnicodeScalarOffset: Int) throws {
        guard !buffer.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TerminalSnapshotViolation.containsNUL
        }
        guard buffer.utf8.count <= wdsMaximumTerminalBufferBytes else {
            throw TerminalSnapshotViolation.bufferTooLarge
        }
        guard cursorUnicodeScalarOffset >= 0,
              cursorUnicodeScalarOffset <= buffer.unicodeScalars.count else {
            throw TerminalSnapshotViolation.invalidCursor
        }

        self.buffer = buffer
        self.bufferSHA256 = sha256UTF8(buffer)
        self.cursorUnicodeScalarOffset = cursorUnicodeScalarOffset
    }

    private enum CodingKeys: String, CodingKey {
        case buffer
        case bufferSHA256 = "buffer_sha256"
        case cursorUnicodeScalarOffset = "cursor_unicode_scalar_offset"
    }
}

public enum TerminalSnapshotViolation: Error, Equatable, Sendable {
    case containsNUL
    case bufferTooLarge
    case invalidCursor
}

public struct TerminalResolveRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let operation: String
    public let surface: TerminalSurface
    public let snapshot: TerminalBufferSnapshot

    public init(
        requestID: String,
        surface: TerminalSurface,
        snapshot: TerminalBufferSnapshot
    ) {
        self.protocolVersion = wdsTerminalProtocolVersion
        self.requestID = requestID
        self.operation = "resolve_accepted_deletion"
        self.surface = surface
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case operation
        case surface
        case snapshot
    }
}

public enum TerminalResolutionDecision: String, Codable, Equatable, Sendable {
    case passThrough = "pass_through"
    case acceptedDeletion = "accepted_deletion"
}

/// A deletion decision created by WDS.app after an explicit user acceptance.
///
/// The adapter never accepts a complete replacement string from the callback.
/// It locally removes exactly this scalar range after rechecking the whole-buffer
/// digest, cursor, and target digest.
public struct AcceptedTerminalDeletion: Codable, Equatable, Sendable {
    public let expectedBufferSHA256: String
    public let expectedCursorUnicodeScalarOffset: Int
    public let rangeStartUnicodeScalarOffset: Int
    public let rangeLengthUnicodeScalars: Int
    public let expectedTargetSHA256: String
    public let acceptanceID: String
    public let explicitlyAccepted: Bool

    public init(
        expectedBufferSHA256: String,
        expectedCursorUnicodeScalarOffset: Int,
        rangeStartUnicodeScalarOffset: Int,
        rangeLengthUnicodeScalars: Int,
        expectedTargetSHA256: String,
        acceptanceID: String,
        explicitlyAccepted: Bool
    ) {
        self.expectedBufferSHA256 = expectedBufferSHA256
        self.expectedCursorUnicodeScalarOffset = expectedCursorUnicodeScalarOffset
        self.rangeStartUnicodeScalarOffset = rangeStartUnicodeScalarOffset
        self.rangeLengthUnicodeScalars = rangeLengthUnicodeScalars
        self.expectedTargetSHA256 = expectedTargetSHA256
        self.acceptanceID = acceptanceID
        self.explicitlyAccepted = explicitlyAccepted
    }

    private enum CodingKeys: String, CodingKey {
        case expectedBufferSHA256 = "expected_buffer_sha256"
        case expectedCursorUnicodeScalarOffset = "expected_cursor_unicode_scalar_offset"
        case rangeStartUnicodeScalarOffset = "range_start_unicode_scalar_offset"
        case rangeLengthUnicodeScalars = "range_length_unicode_scalars"
        case expectedTargetSHA256 = "expected_target_sha256"
        case acceptanceID = "acceptance_id"
        case explicitlyAccepted = "explicitly_accepted"
    }
}

public struct TerminalResolveResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let decision: TerminalResolutionDecision
    public let deletion: AcceptedTerminalDeletion?

    public init(
        protocolVersion: Int = wdsTerminalProtocolVersion,
        requestID: String,
        decision: TerminalResolutionDecision,
        deletion: AcceptedTerminalDeletion? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.decision = decision
        self.deletion = deletion
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case decision
        case deletion
    }
}
