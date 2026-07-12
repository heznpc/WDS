import ApplicationServices
import Foundation
import Testing
@testable import WDSAxBridgeCore

@Test("optional subrole maps both supported AX absence signals to absent")
func mapsOptionalSubroleAbsenceSignals() {
    #expect(
        focusedValueSecurityMetadataReadStatus(error: .noValue, attribute: .subrole) == .absent
    )
    #expect(
        focusedValueSecurityMetadataReadStatus(error: .attributeUnsupported, attribute: .subrole) == .absent
    )
}

@Test("required role keeps AX absence signals unavailable")
func keepsRequiredRoleAbsenceUnavailable() {
    #expect(
        focusedValueSecurityMetadataReadStatus(error: .noValue, attribute: .role) == .unavailable
    )
    #expect(
        focusedValueSecurityMetadataReadStatus(error: .attributeUnsupported, attribute: .role) == .unavailable
    )
}

@Test("metadata read mapping preserves success and unrelated failures")
func mapsMetadataReadSuccessAndOtherFailures() {
    #expect(
        focusedValueSecurityMetadataReadStatus(error: .success, attribute: .subrole) == .success
    )
    #expect(
        focusedValueSecurityMetadataReadStatus(error: .cannotComplete, attribute: .subrole) == .unavailable
    )
}

@Test("focused values allow exactly 64 KiB in both encodings")
func allowsFocusedValueAtEncodedSizeLimit() {
    #expect(
        focusedValueSizeDecision(String(repeating: "😀", count: 16_384)) == .allow
    )
}

@Test("focused values reject a UTF-8 encoding over 64 KiB")
func rejectsOversizedUTF8FocusedValue() {
    #expect(
        focusedValueSizeDecision(String(repeating: "가", count: 21_846))
            == .deny(exceededEncoding: .utf8)
    )
}

@Test("focused values reject a UTF-16 encoding over 64 KiB")
func rejectsOversizedUTF16FocusedValue() {
    #expect(
        focusedValueSizeDecision(String(repeating: "a", count: 32_769))
            == .deny(exceededEncoding: .utf16)
    )
}

@Test("known non-secure role and explicitly absent subrole allow a value read")
func allowsKnownNonSecureMetadata() {
    #expect(
        focusedValueSecurityDecision(
            role: .value("AXTextArea"),
            subrole: .absent
        ) == .allow
    )
}

@Test("secure role denies a value read without requiring subrole metadata")
func deniesSecureRoleImmediately() {
    #expect(
        focusedValueSecurityDecision(
            role: .value("AXSecureTextField"),
            subrole: .unavailable
        ) == .secure
    )
}

@Test("secure subrole denies a value read")
func deniesSecureSubrole() {
    #expect(
        focusedValueSecurityDecision(
            role: .value("AXTextField"),
            subrole: .value("AXSecureTextField")
        ) == .secure
    )
}

@Test("unknown or invalid role metadata fails closed", arguments: [
    FocusedValueSecurityMetadata.unavailable,
    .absent,
    .value(""),
])
func deniesUnknownRole(role: FocusedValueSecurityMetadata) {
    #expect(
        focusedValueSecurityDecision(role: role, subrole: .absent)
            == .deny(unavailableAttribute: .role)
    )
}

@Test("unknown or invalid subrole metadata fails closed", arguments: [
    FocusedValueSecurityMetadata.unavailable,
    .value(""),
])
func deniesUnknownSubrole(subrole: FocusedValueSecurityMetadata) {
    #expect(
        focusedValueSecurityDecision(
            role: .value("AXTextArea"),
            subrole: subrole
        ) == .deny(unavailableAttribute: .subrole)
    )
}

@Test("exact active frontmost process allows a value read")
func allowsExactTargetProcess() {
    #expect(
        focusedValueTargetDecision(
            expectedProcessIdentifier: 42,
            actualProcessIdentifier: 42,
            frontmostProcessIdentifier: 42,
            targetApplicationIsActive: true
        ) == .allow
    )
}

@Test("a different focused element process fails closed")
func deniesProcessIdentifierMismatch() {
    #expect(
        focusedValueTargetDecision(
            expectedProcessIdentifier: 42,
            actualProcessIdentifier: 77,
            frontmostProcessIdentifier: 42,
            targetApplicationIsActive: true
        ) == .processIdentifierMismatch
    )
}

@Test("invalid process identifiers fail closed", arguments: [
    (expected: pid_t(0), actual: pid_t(0)),
    (expected: pid_t(42), actual: pid_t(0)),
    (expected: pid_t(0), actual: pid_t(42)),
])
func deniesInvalidProcessIdentifiers(input: (expected: pid_t, actual: pid_t)) {
    #expect(
        focusedValueTargetDecision(
            expectedProcessIdentifier: input.expected,
            actualProcessIdentifier: input.actual,
            frontmostProcessIdentifier: input.expected,
            targetApplicationIsActive: true
        ) == .processIdentifierMismatch
    )
}

@Test("inactive or non-frontmost target fails closed", arguments: [
    (frontmost: Optional<pid_t>.some(77), active: true),
    (frontmost: Optional<pid_t>.some(42), active: false),
    (frontmost: Optional<pid_t>.none, active: true),
])
func deniesInactiveOrBackgroundTarget(input: (frontmost: pid_t?, active: Bool)) {
    #expect(
        focusedValueTargetDecision(
            expectedProcessIdentifier: 42,
            actualProcessIdentifier: 42,
            frontmostProcessIdentifier: input.frontmost,
            targetApplicationIsActive: input.active
        ) == .targetApplicationNotFrontmost
    )
}
