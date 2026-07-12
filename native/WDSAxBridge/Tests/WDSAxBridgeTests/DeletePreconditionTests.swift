import Foundation
import Testing
@testable import WDSAxBridgeCore

@Test("rejects an otherwise modified draft even when the same target remains")
func rejectsModifiedDraftContainingTarget() {
    let target = "지울 부분"
    let original = "앞 지울 부분 뒤"
    let modified = "바뀐 앞 지울 부분 뒤"
    let range = (original as NSString).range(of: target)
    let expected = DeletePrecondition(
        valueSHA256: sha256UTF8(original),
        processIdentifier: 42,
        range: range
    )
    let snapshot = DeletePreconditionSnapshot(
        value: modified,
        target: target,
        range: (modified as NSString).range(of: target),
        processIdentifier: 42,
        frontmostProcessIdentifier: 42,
        targetApplicationIsActive: true
    )

    #expect(throws: DeletePreconditionViolation.valueDigestMismatch) {
        try validateDeletePrecondition(expected, against: snapshot)
    }
}

@Test("rejects a matching draft when focus moved to another process")
func rejectsFrontmostProcessMismatch() {
    let value = "앞 지울 부분 뒤"
    let target = "지울 부분"
    let range = (value as NSString).range(of: target)
    let expected = DeletePrecondition(
        valueSHA256: sha256UTF8(value),
        processIdentifier: 42,
        range: range
    )
    let snapshot = DeletePreconditionSnapshot(
        value: value,
        target: target,
        range: range,
        processIdentifier: 42,
        frontmostProcessIdentifier: 77,
        targetApplicationIsActive: false
    )

    #expect(throws: DeletePreconditionViolation.targetApplicationNotFrontmost) {
        try validateDeletePrecondition(expected, against: snapshot)
    }
}

@Test("rejects an explicit digest mismatch")
func rejectsDigestMismatch() {
    let value = "앞 지울 부분 뒤"
    let target = "지울 부분"
    let range = (value as NSString).range(of: target)
    let expected = DeletePrecondition(
        valueSHA256: String(repeating: "0", count: 64),
        processIdentifier: 42,
        range: range
    )
    let snapshot = DeletePreconditionSnapshot(
        value: value,
        target: target,
        range: range,
        processIdentifier: 42,
        frontmostProcessIdentifier: 42,
        targetApplicationIsActive: true
    )

    #expect(throws: DeletePreconditionViolation.valueDigestMismatch) {
        try validateDeletePrecondition(expected, against: snapshot)
    }
}

@Test("accepts only the exact digest, process, range, and active frontmost app")
func acceptsExactSnapshot() throws {
    let value = "앞 지울 부분 뒤"
    let target = "지울 부분"
    let range = (value as NSString).range(of: target)
    let expected = DeletePrecondition(
        valueSHA256: sha256UTF8(value),
        processIdentifier: 42,
        range: range
    )
    let snapshot = DeletePreconditionSnapshot(
        value: value,
        target: target,
        range: range,
        processIdentifier: 42,
        frontmostProcessIdentifier: 42,
        targetApplicationIsActive: true
    )

    try validateDeletePrecondition(expected, against: snapshot)
}
