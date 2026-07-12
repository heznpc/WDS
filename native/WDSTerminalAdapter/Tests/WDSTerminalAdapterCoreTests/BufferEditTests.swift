import Foundation
import Testing
@testable import WDSTerminalAdapterCore

private func request(
    _ value: String,
    cursor: Int,
    requestID: String = "request-1"
) throws -> TerminalResolveRequest {
    TerminalResolveRequest(
        requestID: requestID,
        surface: TerminalSurface(kind: .zshZLE),
        snapshot: try TerminalBufferSnapshot(
            buffer: value,
            cursorUnicodeScalarOffset: cursor
        )
    )
}

private func acceptedDeletion(
    request: TerminalResolveRequest,
    target: String,
    start: Int,
    length: Int,
    explicitlyAccepted: Bool = true
) -> TerminalResolveResponse {
    TerminalResolveResponse(
        requestID: request.requestID,
        decision: .acceptedDeletion,
        deletion: AcceptedTerminalDeletion(
            expectedBufferSHA256: request.snapshot.bufferSHA256,
            expectedCursorUnicodeScalarOffset: request.snapshot.cursorUnicodeScalarOffset,
            rangeStartUnicodeScalarOffset: start,
            rangeLengthUnicodeScalars: length,
            expectedTargetSHA256: sha256UTF8(target),
            acceptanceID: "acceptance-1",
            explicitlyAccepted: explicitlyAccepted
        )
    )
}

@Test("applies exactly one accepted Korean deletion and adjusts a later cursor")
func appliesExactDeletion() throws {
    let original = "앞 지울 부분 뒤"
    let req = try request(original, cursor: original.unicodeScalars.count)
    let target = "지울 부분"
    let targetRange = original.range(of: target)!
    let start = original.unicodeScalars.distance(
        from: original.unicodeScalars.startIndex,
        to: targetRange.lowerBound
    )
    let response = acceptedDeletion(
        request: req,
        target: target,
        start: start,
        length: target.unicodeScalars.count
    )

    #expect(
        try resolveTerminalResponse(response, for: req)
            == .applied(
                AppliedTerminalDeletion(
                    buffer: "앞  뒤",
                    cursorUnicodeScalarOffset: "앞  뒤".unicodeScalars.count,
                    acceptanceID: "acceptance-1"
                )
            )
    )
}

@Test("pass-through never edits the buffer")
func passThroughDoesNotEdit() throws {
    let req = try request("그대로", cursor: 3)
    let response = TerminalResolveResponse(
        requestID: req.requestID,
        decision: .passThrough
    )

    #expect(try resolveTerminalResponse(response, for: req) == .passThrough)
}

@Test("rejects deletion without explicit acceptance")
func rejectsImplicitDeletion() throws {
    let req = try request("지울 부분", cursor: 5)
    let response = acceptedDeletion(
        request: req,
        target: "지울 부분",
        start: 0,
        length: 5,
        explicitlyAccepted: false
    )

    #expect(throws: TerminalResolutionViolation.notExplicitlyAccepted) {
        try resolveTerminalResponse(response, for: req)
    }
}

@Test("rejects a stale whole-buffer digest even when the same target remains")
func rejectsStaleDigest() throws {
    let req = try request("앞 지울 부분 뒤", cursor: 9)
    let stale = try request("다른 앞 지울 부분 뒤", cursor: 12)
    let response = acceptedDeletion(
        request: stale,
        target: "지울 부분",
        start: 5,
        length: 5
    )
    let rebound = TerminalResolveResponse(
        requestID: req.requestID,
        decision: .acceptedDeletion,
        deletion: response.deletion
    )

    #expect(throws: TerminalResolutionViolation.valueDigestMismatch) {
        try resolveTerminalResponse(rebound, for: req)
    }
}

@Test("rejects a changed cursor at the submit boundary")
func rejectsChangedCursor() throws {
    let req = try request("앞 지울 부분 뒤", cursor: 9)
    let otherCursorRequest = try request("앞 지울 부분 뒤", cursor: 0)
    let response = acceptedDeletion(
        request: otherCursorRequest,
        target: "지울 부분",
        start: 2,
        length: 5
    )
    let rebound = TerminalResolveResponse(
        requestID: req.requestID,
        decision: .acceptedDeletion,
        deletion: response.deletion
    )

    #expect(throws: TerminalResolutionViolation.cursorMismatch) {
        try resolveTerminalResponse(rebound, for: req)
    }
}

@Test("rejects a range whose current target has a different digest")
func rejectsTargetMismatch() throws {
    let req = try request("앞 지울 부분 뒤", cursor: 9)
    let response = acceptedDeletion(
        request: req,
        target: "엉뚱한 값",
        start: 2,
        length: 5
    )

    #expect(throws: TerminalResolutionViolation.targetDigestMismatch) {
        try resolveTerminalResponse(response, for: req)
    }
}

@Test("rejects an out-of-bounds deletion range")
func rejectsOutOfBoundsRange() throws {
    let req = try request("짧은 값", cursor: 4)
    let response = acceptedDeletion(
        request: req,
        target: "값",
        start: 3,
        length: 2
    )

    #expect(throws: TerminalResolutionViolation.invalidRange) {
        try resolveTerminalResponse(response, for: req)
    }
}

@Test("rejects a response for another callback request")
func rejectsAnotherRequestID() throws {
    let req = try request("지울 값", cursor: 4)
    let response = TerminalResolveResponse(
        requestID: "another-request",
        decision: .passThrough
    )

    #expect(throws: TerminalResolutionViolation.requestIDMismatch) {
        try resolveTerminalResponse(response, for: req)
    }
}

@Test("uses Unicode scalar offsets without splitting a multi-scalar emoji")
func deletesMultiScalarEmoji() throws {
    let target = "👨‍👩‍👧‍👦"
    let original = "A\(target)B"
    let req = try request(original, cursor: original.unicodeScalars.count)
    let response = acceptedDeletion(
        request: req,
        target: target,
        start: 1,
        length: target.unicodeScalars.count
    )

    #expect(
        try resolveTerminalResponse(response, for: req)
            == .applied(
                AppliedTerminalDeletion(
                    buffer: "AB",
                    cursorUnicodeScalarOffset: 2,
                    acceptanceID: "acceptance-1"
                )
            )
    )
}

@Test("rejects invalid snapshots before a callback can receive them")
func rejectsInvalidSnapshots() {
    #expect(throws: TerminalSnapshotViolation.containsNUL) {
        try TerminalBufferSnapshot(buffer: "a\0b", cursorUnicodeScalarOffset: 1)
    }
    #expect(throws: TerminalSnapshotViolation.invalidCursor) {
        try TerminalBufferSnapshot(buffer: "한글", cursorUnicodeScalarOffset: 3)
    }
}

@Test("wire frame preserves multiline and trailing newlines")
func wireFrameRoundTrip() throws {
    let req = try request("첫 줄\n둘째 줄\n", cursor: 9)
    let decoded = try decodeTerminalWireFrame(
        TerminalResolveRequest.self,
        from: encodeTerminalWireFrame(req)
    )

    #expect(decoded == req)
}

@Test("server authentication proof is nonce-bound and rejects a wrong token")
func authenticatesServerBeforeBufferTransfer() throws {
    let token = String(repeating: "ab", count: 32)
    let otherToken = String(repeating: "cd", count: 32)
    let nonce = "nonce-1"
    let proofValue = try #require(
        terminalServerAuthenticationProof(tokenHex: token, nonce: nonce)
    )
    let proof = TerminalServerAuthenticationProof(
        nonce: nonce,
        proofHMACSHA256: proofValue
    )

    #expect(
        verifyTerminalServerAuthenticationProof(
            proof,
            tokenHex: token,
            nonce: nonce
        )
    )
    #expect(
        !verifyTerminalServerAuthenticationProof(
            proof,
            tokenHex: otherToken,
            nonce: nonce
        )
    )
    #expect(
        !verifyTerminalServerAuthenticationProof(
            proof,
            tokenHex: token,
            nonce: "nonce-2"
        )
    )
}

@Test("authentication token must be exactly 32 lowercase-hex bytes")
func validatesAuthenticationToken() {
    #expect(isValidTerminalAuthenticationToken(String(repeating: "01", count: 32)))
    #expect(!isValidTerminalAuthenticationToken(String(repeating: "A1", count: 32)))
    #expect(!isValidTerminalAuthenticationToken("01"))
}
