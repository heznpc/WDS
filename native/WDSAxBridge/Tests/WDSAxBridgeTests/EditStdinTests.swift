import Foundation
import Testing
@testable import WDSAxBridgeCore

private func payload(_ target: String, _ replacement: String) -> Data {
    Data(target.utf8) + Data([0]) + Data(replacement.utf8)
}

// Result's success type is a tuple, so the Result itself is not Equatable;
// compare the extracted error, which is.
private func editError(_ result: Result<(target: String, replacement: String), EditStdinError>) -> EditStdinError? {
    if case .failure(let error) = result { return error }
    return nil
}

@Test("splits a well-formed target/replacement payload on the single NUL")
func splitsWellFormedEdit() {
    let result = parseEditStdin(payload("봐주실 수 있을까요", "봐줘"))
    guard case .success(let edit) = result else {
        Issue.record("expected success, got \(result)")
        return
    }
    #expect(edit.target == "봐주실 수 있을까요")
    #expect(edit.replacement == "봐줘")
}

@Test("allows an empty replacement (command-level rules reject it, not the framing)")
func allowsEmptyReplacement() {
    let result = parseEditStdin(payload("혹시", ""))
    guard case .success(let edit) = result else {
        Issue.record("expected success, got \(result)")
        return
    }
    #expect(edit.target == "혹시")
    #expect(edit.replacement == "")
}

@Test("keeps only the first NUL as the separator; a NUL in the replacement is rejected")
func rejectsNulInsideReplacement() {
    let data = Data("혹시".utf8) + Data([0]) + Data("봐".utf8) + Data([0]) + Data("줘".utf8)
    #expect(editError(parseEditStdin(data)) == .invalidEncoding)
}

@Test("rejects a payload with no NUL separator")
func rejectsMissingSeparator() {
    #expect(editError(parseEditStdin(Data("혹시봐줘".utf8))) == .missingSeparator)
}

@Test("rejects non-UTF-8 bytes")
func rejectsInvalidUTF8() {
    let data = Data([0xFF, 0xFE]) + Data([0]) + Data("봐줘".utf8)
    #expect(editError(parseEditStdin(data)) == .invalidEncoding)
}

@Test("rejects a payload over the transport size cap before any split")
func rejectsOversizePayload() {
    let oversize = Data(repeating: 0x41, count: maximumEditStdinByteCount + 1)
    #expect(editError(parseEditStdin(oversize)) == .tooLarge)
}

@Test("accepts a payload exactly at the transport size cap")
func acceptsPayloadAtSizeCap() {
    // target is one 'A', a NUL, then filler up to the cap.
    let fillerCount = maximumEditStdinByteCount - 2
    let data = Data([0x41, 0x00]) + Data(repeating: 0x41, count: fillerCount)
    guard case .success(let edit) = parseEditStdin(data) else {
        Issue.record("expected success at the size cap")
        return
    }
    #expect(edit.target == "A")
    #expect(edit.replacement.count == fillerCount)
}
