import CryptoKit
import Foundation

public enum DeletePreconditionViolation: Error, Equatable {
    case valueDigestMismatch
    case processIdentifierMismatch
    case rangeMismatch
    case targetApplicationNotFrontmost
}

public struct DeletePrecondition {
    public let valueSHA256: String
    public let processIdentifier: pid_t
    public let range: NSRange
    public let allowsInsertion: Bool

    public init(valueSHA256: String, processIdentifier: pid_t, range: NSRange, allowsInsertion: Bool = false) {
        self.valueSHA256 = valueSHA256
        self.processIdentifier = processIdentifier
        self.range = range
        self.allowsInsertion = allowsInsertion
    }
}

public struct DeletePreconditionSnapshot {
    public let value: String
    public let target: String
    public let range: NSRange
    public let processIdentifier: pid_t
    public let frontmostProcessIdentifier: pid_t?
    public let targetApplicationIsActive: Bool

    public init(
        value: String,
        target: String,
        range: NSRange,
        processIdentifier: pid_t,
        frontmostProcessIdentifier: pid_t?,
        targetApplicationIsActive: Bool
    ) {
        self.value = value
        self.target = target
        self.range = range
        self.processIdentifier = processIdentifier
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.targetApplicationIsActive = targetApplicationIsActive
    }
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

/// Validates every cross-process delete invariant without mutating accessibility
/// state. Digest comparison deliberately precedes range comparison: a draft that
/// still contains the target is stale if any other byte changed.
public func validateDeletePrecondition(
    _ expected: DeletePrecondition,
    against actual: DeletePreconditionSnapshot
) throws {
    guard sha256UTF8(actual.value) == expected.valueSHA256 else {
        throw DeletePreconditionViolation.valueDigestMismatch
    }
    guard actual.processIdentifier == expected.processIdentifier else {
        throw DeletePreconditionViolation.processIdentifierMismatch
    }
    guard NSEqualRanges(actual.range, expected.range) else {
        throw DeletePreconditionViolation.rangeMismatch
    }

    let source = actual.value as NSString
    guard actual.range.location != NSNotFound,
          actual.range.location >= 0,
          actual.range.length >= 0,
          actual.range.length > 0 || (expected.allowsInsertion && actual.target.isEmpty),
          actual.range.location <= source.length,
          actual.range.length <= source.length - actual.range.location,
          let textRange = Range(actual.range, in: actual.value),
          actual.value.indices.contains(textRange.lowerBound) || textRange.lowerBound == actual.value.endIndex,
          actual.value.indices.contains(textRange.upperBound) || textRange.upperBound == actual.value.endIndex,
          source.substring(with: actual.range) == actual.target else {
        throw DeletePreconditionViolation.rangeMismatch
    }

    guard actual.targetApplicationIsActive,
          actual.frontmostProcessIdentifier == expected.processIdentifier else {
        throw DeletePreconditionViolation.targetApplicationNotFrontmost
    }
}
