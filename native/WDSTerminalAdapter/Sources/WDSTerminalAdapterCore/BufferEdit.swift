import CryptoKit
import Foundation

public enum TerminalResolutionViolation: Error, Equatable, Sendable {
    case protocolVersionMismatch
    case requestIDMismatch
    case malformedSnapshot
    case missingDeletion
    case notExplicitlyAccepted
    case invalidAcceptanceID
    case valueDigestMismatch
    case cursorMismatch
    case invalidRange
    case targetDigestMismatch
}

public struct AppliedTerminalDeletion: Equatable, Sendable {
    public let buffer: String
    public let cursorUnicodeScalarOffset: Int
    public let acceptanceID: String

    public init(
        buffer: String,
        cursorUnicodeScalarOffset: Int,
        acceptanceID: String
    ) {
        self.buffer = buffer
        self.cursorUnicodeScalarOffset = cursorUnicodeScalarOffset
        self.acceptanceID = acceptanceID
    }
}

public enum TerminalResolution: Equatable, Sendable {
    case passThrough
    case applied(AppliedTerminalDeletion)
}

public func sha256UTF8(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

public func isCanonicalSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
}

/// Applies only one explicitly accepted, exact deletion to the request snapshot.
/// Every validation failure throws before a new buffer is produced.
public func resolveTerminalResponse(
    _ response: TerminalResolveResponse,
    for request: TerminalResolveRequest
) throws -> TerminalResolution {
    guard response.protocolVersion == wdsTerminalProtocolVersion,
          request.protocolVersion == wdsTerminalProtocolVersion else {
        throw TerminalResolutionViolation.protocolVersionMismatch
    }
    guard response.requestID == request.requestID else {
        throw TerminalResolutionViolation.requestIDMismatch
    }

    let snapshot = request.snapshot
    guard !snapshot.buffer.unicodeScalars.contains(where: { $0.value == 0 }),
          snapshot.buffer.utf8.count <= wdsMaximumTerminalBufferBytes,
          snapshot.cursorUnicodeScalarOffset >= 0,
          snapshot.cursorUnicodeScalarOffset <= snapshot.buffer.unicodeScalars.count,
          isCanonicalSHA256(snapshot.bufferSHA256),
          sha256UTF8(snapshot.buffer) == snapshot.bufferSHA256 else {
        throw TerminalResolutionViolation.malformedSnapshot
    }

    guard response.decision == .acceptedDeletion else {
        return .passThrough
    }
    guard let deletion = response.deletion else {
        throw TerminalResolutionViolation.missingDeletion
    }
    guard deletion.explicitlyAccepted else {
        throw TerminalResolutionViolation.notExplicitlyAccepted
    }
    guard isValidAcceptanceID(deletion.acceptanceID) else {
        throw TerminalResolutionViolation.invalidAcceptanceID
    }
    guard isCanonicalSHA256(deletion.expectedBufferSHA256),
          deletion.expectedBufferSHA256 == snapshot.bufferSHA256 else {
        throw TerminalResolutionViolation.valueDigestMismatch
    }
    guard deletion.expectedCursorUnicodeScalarOffset == snapshot.cursorUnicodeScalarOffset else {
        throw TerminalResolutionViolation.cursorMismatch
    }
    guard deletion.rangeStartUnicodeScalarOffset >= 0,
          deletion.rangeLengthUnicodeScalars > 0 else {
        throw TerminalResolutionViolation.invalidRange
    }

    let scalars = snapshot.buffer.unicodeScalars
    guard let rangeStart = scalars.index(
        scalars.startIndex,
        offsetBy: deletion.rangeStartUnicodeScalarOffset,
        limitedBy: scalars.endIndex
    ),
    let rangeEnd = scalars.index(
        rangeStart,
        offsetBy: deletion.rangeLengthUnicodeScalars,
        limitedBy: scalars.endIndex
    ),
    rangeStart < rangeEnd else {
        throw TerminalResolutionViolation.invalidRange
    }

    let target = String(scalars[rangeStart..<rangeEnd])
    guard isCanonicalSHA256(deletion.expectedTargetSHA256),
          sha256UTF8(target) == deletion.expectedTargetSHA256 else {
        throw TerminalResolutionViolation.targetDigestMismatch
    }

    let before = String(scalars[..<rangeStart])
    let after = String(scalars[rangeEnd...])
    let newCursor: Int
    let deleteStart = deletion.rangeStartUnicodeScalarOffset
    let deleteEnd = deleteStart + deletion.rangeLengthUnicodeScalars

    if snapshot.cursorUnicodeScalarOffset <= deleteStart {
        newCursor = snapshot.cursorUnicodeScalarOffset
    } else if snapshot.cursorUnicodeScalarOffset <= deleteEnd {
        newCursor = deleteStart
    } else {
        newCursor = snapshot.cursorUnicodeScalarOffset - deletion.rangeLengthUnicodeScalars
    }

    return .applied(
        AppliedTerminalDeletion(
            buffer: before + after,
            cursorUnicodeScalarOffset: newCursor,
            acceptanceID: deletion.acceptanceID
        )
    )
}

private func isValidAcceptanceID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 256 else {
        return false
    }
    return value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x21 && scalar.value <= 0x7e
    }
}
