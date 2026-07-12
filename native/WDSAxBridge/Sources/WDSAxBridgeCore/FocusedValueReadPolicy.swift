import ApplicationServices
import Foundation

public let maximumFocusedValueEncodedByteCount = 64 * 1_024

public enum FocusedValueEncoding: String, Equatable, Sendable {
    case utf8
    case utf16
}

public enum FocusedValueSizeDecision: Equatable, Sendable {
    case allow
    case deny(exceededEncoding: FocusedValueEncoding)
}

/// Applies the same 64 KiB ceiling to both supported encodings. UTF-16 size is
/// measured as encoded bytes rather than code-unit count.
public func focusedValueSizeDecision(_ value: String) -> FocusedValueSizeDecision {
    guard value.utf8.count <= maximumFocusedValueEncodedByteCount else {
        return .deny(exceededEncoding: .utf8)
    }
    guard value.utf16.count <= maximumFocusedValueEncodedByteCount / MemoryLayout<UInt16>.size else {
        return .deny(exceededEncoding: .utf16)
    }
    return .allow
}

public enum FocusedValueSecurityAttribute: String, Equatable, Sendable {
    case role
    case subrole
}

public enum FocusedValueSecurityMetadataReadStatus: Equatable, Sendable {
    case success
    case absent
    case unavailable
}

/// Maps AX metadata read results without weakening the required-role boundary.
/// A normal text control may omit its optional `AXSubrole` by returning either
/// `noValue` or `attributeUnsupported`; the same errors for `AXRole` remain
/// unknown and therefore fail closed before `AXValue` is read.
public func focusedValueSecurityMetadataReadStatus(
    error: AXError,
    attribute: FocusedValueSecurityAttribute
) -> FocusedValueSecurityMetadataReadStatus {
    guard error != .success else { return .success }
    if attribute == .subrole,
       error == .noValue || error == .attributeUnsupported {
        return .absent
    }
    return .unavailable
}

/// A security-sensitive AX attribute read distinguishes an explicitly absent
/// optional value from a read whose result is unknown.
public enum FocusedValueSecurityMetadata: Equatable, Sendable {
    case value(String)
    case absent
    case unavailable
}

public enum FocusedValueSecurityDecision: Equatable, Sendable {
    case allow
    case secure
    case deny(unavailableAttribute: FocusedValueSecurityAttribute)
}

/// Decides whether a focused element's `AXValue` may be read. A known secure
/// role wins immediately. Otherwise role and subrole metadata must be known;
/// an explicitly absent optional subrole is the only absent value that is safe.
public func focusedValueSecurityDecision(
    role: FocusedValueSecurityMetadata,
    subrole: FocusedValueSecurityMetadata
) -> FocusedValueSecurityDecision {
    switch role {
    case .value("AXSecureTextField"):
        return .secure
    case .value(let role) where !role.isEmpty:
        break
    case .value, .absent, .unavailable:
        return .deny(unavailableAttribute: .role)
    }

    switch subrole {
    case .value("AXSecureTextField"):
        return .secure
    case .value(let subrole) where !subrole.isEmpty:
        return .allow
    case .absent:
        return .allow
    case .value, .unavailable:
        return .deny(unavailableAttribute: .subrole)
    }
}

public enum FocusedValueTargetDecision: Equatable, Sendable {
    case allow
    case processIdentifierMismatch
    case targetApplicationNotFrontmost
}

/// Ensures a value read remains scoped to one exact active, frontmost process.
public func focusedValueTargetDecision(
    expectedProcessIdentifier: pid_t,
    actualProcessIdentifier: pid_t,
    frontmostProcessIdentifier: pid_t?,
    targetApplicationIsActive: Bool
) -> FocusedValueTargetDecision {
    guard expectedProcessIdentifier > 0,
          actualProcessIdentifier > 0,
          actualProcessIdentifier == expectedProcessIdentifier else {
        return .processIdentifierMismatch
    }
    guard targetApplicationIsActive,
          frontmostProcessIdentifier == expectedProcessIdentifier else {
        return .targetApplicationNotFrontmost
    }
    return .allow
}
