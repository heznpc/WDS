import Foundation
import Testing
@testable import WDSAxBridgeCore

@Test func replacementPayloadPreservesUnicodeAndMultilineText() throws {
    let data = try JSONSerialization.data(withJSONObject: ["target": "파일를", "replacement": "파일을\n😀"])
    let input = try ExactEditInput.decode(data)
    #expect(input.target == "파일를")
    #expect(input.replacement == "파일을\n😀")
}

@Test func malformedOrDestructiveReplacementIsRefused() throws {
    for pair in [["target": "word", "replacement": ""], ["target": "same", "replacement": "same"], ["target": "x", "replacement": "a\0b"]] {
        #expect(throws: (any Error).self) { try ExactEditInput.decode(JSONSerialization.data(withJSONObject: pair)) }
    }
    #expect(throws: (any Error).self) { try ExactEditInput.decode(Data("{".utf8)) }
    #expect(throws: (any Error).self) { try ExactEditInput.decode(Data(repeating: 65, count: ExactEditInput.maximumBytes + 1)) }
}

@Test func insertionRequiresAnExplicitPrecondition() throws {
    let source = "hello 😀"
    let range = NSRange(location: (source as NSString).length, length: 0)
    let snapshot = DeletePreconditionSnapshot(value: source, target: "", range: range,
        processIdentifier: 42, frontmostProcessIdentifier: 42, targetApplicationIsActive: true)
    #expect(throws: DeletePreconditionViolation.rangeMismatch) {
        try validateDeletePrecondition(DeletePrecondition(valueSHA256: sha256UTF8(source), processIdentifier: 42, range: range), against: snapshot)
    }
    try validateDeletePrecondition(DeletePrecondition(valueSHA256: sha256UTF8(source), processIdentifier: 42, range: range, allowsInsertion: true), against: snapshot)
    let splitEmoji = NSRange(location: range.location - 1, length: 0)
    let invalid = DeletePreconditionSnapshot(value: source, target: "", range: splitEmoji,
        processIdentifier: 42, frontmostProcessIdentifier: 42, targetApplicationIsActive: true)
    #expect(throws: DeletePreconditionViolation.rangeMismatch) {
        try validateDeletePrecondition(DeletePrecondition(valueSHA256: sha256UTF8(source), processIdentifier: 42, range: splitEmoji, allowsInsertion: true), against: invalid)
    }
}
