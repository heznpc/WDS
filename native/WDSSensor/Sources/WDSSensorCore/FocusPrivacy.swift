import ApplicationServices

public enum FocusSecurityAttribute: String, Equatable, Sendable {
    case role
    case subrole
}

public enum FocusSecurityAttributeReadStatus: Equatable, Sendable {
    case success
    case absent
    case unavailable
}

/// Classifies the result of reading security-sensitive AX metadata before any
/// focused value is accessed. `AXSubrole` is optional for ordinary AppKit text
/// controls: those controls may report either `noValue` or
/// `attributeUnsupported` when no subrole exists. Neither result is evidence
/// that the required `AXRole` is absent, so role reads remain fail-closed.
public func focusSecurityAttributeReadStatus(
    error: AXError,
    attribute: FocusSecurityAttribute
) -> FocusSecurityAttributeReadStatus {
    guard error != .success else { return .success }
    if attribute == .subrole,
       error == .noValue || error == .attributeUnsupported {
        return .absent
    }
    return .unavailable
}

public enum FocusSecurityAttributeValue: Equatable, Sendable {
    case value(String)
    case absent
    case unavailable
}

public enum FocusSecurityDecision: Equatable, Sendable {
    case allow
    case secure
    case ignore(unavailableAttribute: FocusSecurityAttribute)
}

/// Decides whether AXValue may be read from a focused element. A known secure
/// role wins immediately; otherwise every piece of security metadata must have
/// been read unambiguously before the value is allowed.
public func focusSecurityDecision(
    role: FocusSecurityAttributeValue,
    subrole: FocusSecurityAttributeValue
) -> FocusSecurityDecision {
    switch role {
    case .value("AXSecureTextField"):
        return .secure
    case .value(let role) where !role.isEmpty:
        break
    case .value, .absent, .unavailable:
        return .ignore(unavailableAttribute: .role)
    }

    switch subrole {
    case .value("AXSecureTextField"):
        return .secure
    case .value(let subrole) where !subrole.isEmpty:
        return .allow
    case .absent:
        return .allow
    case .value, .unavailable:
        return .ignore(unavailableAttribute: .subrole)
    }
}

/// Session-local, non-identifying generation counter. The caller compares the
/// actual focused objects privately and reports only whether a transition was
/// observed; no element identity is exposed by this type.
public struct FocusEpochCounter: Equatable, Sendable {
    public private(set) var value: UInt64 = 0
    private var hasObservation = false

    public init() {}

    @discardableResult
    public mutating func observeFocus(didChange: Bool) -> UInt64 {
        if !hasObservation {
            hasObservation = true
            value = 1
        } else if didChange, value < UInt64.max {
            value += 1
        }
        return value
    }
}

public struct SensorOutputOrderGate: Equatable, Sendable {
    public private(set) var didEmitStartAttestation = false

    public init() {}

    /// Focus-scoped events are fail-closed until the configuration attestation
    /// has been emitted. Other events (notably startup errors) remain available.
    public mutating func permits(eventType: String) -> Bool {
        if eventType == "sensor_started" {
            didEmitStartAttestation = true
            return true
        }

        if Self.focusScopedEventTypes.contains(eventType) {
            return didEmitStartAttestation
        }
        return true
    }

    public static func requiresFocusEpoch(eventType: String) -> Bool {
        focusScopedEventTypes.contains(eventType)
    }

    private static let focusScopedEventTypes: Set<String> = [
        "focused_element_ignored",
        "secure_field_ignored",
        "text_snapshot",
        "text_snapshot_error",
    ]
}
