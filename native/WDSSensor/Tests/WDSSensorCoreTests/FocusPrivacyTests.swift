import ApplicationServices
import Testing
@testable import WDSSensorCore

@Test func optionalSubroleTreatsSupportedAbsenceSignalsAsAbsent() {
    #expect(
        focusSecurityAttributeReadStatus(error: .noValue, attribute: .subrole) == .absent
    )
    #expect(
        focusSecurityAttributeReadStatus(error: .attributeUnsupported, attribute: .subrole) == .absent
    )
}

@Test func requiredRoleAbsenceSignalsRemainUnavailable() {
    #expect(
        focusSecurityAttributeReadStatus(error: .noValue, attribute: .role) == .unavailable
    )
    #expect(
        focusSecurityAttributeReadStatus(error: .attributeUnsupported, attribute: .role) == .unavailable
    )
}

@Test func securityMetadataReadStatusPreservesSuccessAndOtherFailures() {
    #expect(
        focusSecurityAttributeReadStatus(error: .success, attribute: .subrole) == .success
    )
    #expect(
        focusSecurityAttributeReadStatus(error: .cannotComplete, attribute: .subrole) == .unavailable
    )
}

@Test func securityPolicyRejectsUnknownRole() {
    #expect(
        focusSecurityDecision(role: .unavailable, subrole: .absent)
            == .ignore(unavailableAttribute: .role)
    )
    #expect(
        focusSecurityDecision(role: .absent, subrole: .absent)
            == .ignore(unavailableAttribute: .role)
    )
}

@Test func securityPolicyRejectsUnknownSubrole() {
    #expect(
        focusSecurityDecision(role: .value("AXTextArea"), subrole: .unavailable)
            == .ignore(unavailableAttribute: .subrole)
    )
}

@Test func securityPolicyAllowsKnownRoleAndExplicitlyAbsentSubrole() {
    #expect(
        focusSecurityDecision(role: .value("AXTextArea"), subrole: .absent) == .allow
    )
}

@Test func securityPolicyBlocksSecureMetadataBeforeAnyValueRead() {
    #expect(
        focusSecurityDecision(role: .value("AXSecureTextField"), subrole: .unavailable)
            == .secure
    )
    #expect(
        focusSecurityDecision(role: .value("AXTextField"), subrole: .value("AXSecureTextField"))
            == .secure
    )
}

@Test func focusEpochChangesOnlyForObservedFocusTransitions() {
    var counter = FocusEpochCounter()

    let initial = counter.observeFocus(didChange: true)
    let unchanged = counter.observeFocus(didChange: false)
    let changed = counter.observeFocus(didChange: true)
    let unchangedAgain = counter.observeFocus(didChange: false)

    #expect(initial == 1)
    #expect(unchanged == 1)
    #expect(changed == 2)
    #expect(unchangedAgain == 2)
}

@Test func focusScopedOutputRequiresStartAttestation() {
    var gate = SensorOutputOrderGate()

    let snapshotBeforeStart = gate.permits(eventType: "text_snapshot")
    let ignoredBeforeStart = gate.permits(eventType: "secure_field_ignored")
    let startupError = gate.permits(eventType: "error")
    let start = gate.permits(eventType: "sensor_started")

    #expect(!snapshotBeforeStart)
    #expect(!ignoredBeforeStart)
    #expect(startupError)
    #expect(start)
    #expect(gate.didEmitStartAttestation)

    let snapshotAfterStart = gate.permits(eventType: "text_snapshot")
    let ignoredAfterStart = gate.permits(eventType: "focused_element_ignored")
    let snapshotErrorAfterStart = gate.permits(eventType: "text_snapshot_error")
    #expect(snapshotAfterStart)
    #expect(ignoredAfterStart)
    #expect(snapshotErrorAfterStart)
}

@Test func focusScopedContractRequiresEpochOnSnapshotsAndIgnoredEvents() {
    #expect(SensorOutputOrderGate.requiresFocusEpoch(eventType: "text_snapshot"))
    #expect(SensorOutputOrderGate.requiresFocusEpoch(eventType: "focused_element_ignored"))
    #expect(SensorOutputOrderGate.requiresFocusEpoch(eventType: "secure_field_ignored"))
    #expect(SensorOutputOrderGate.requiresFocusEpoch(eventType: "text_snapshot_error"))
    #expect(!SensorOutputOrderGate.requiresFocusEpoch(eventType: "sensor_started"))
    #expect(!SensorOutputOrderGate.requiresFocusEpoch(eventType: "mouse_summary"))
}
