import CryptoKit
import Foundation
import XCTest
@testable import WDSAppCore

/// The write path generalised from "remove this span" to "this span becomes
/// that text". A deletion is the same contract with an empty replacement, so
/// these tests only cover what the replacement adds.
final class SafeDeleteReplacementTests: XCTestCase {
    private let source = "이 파일를 열어 줘"
    private let phrase = "파일를"
    private let replacement = "파일을"

    func testExpectedResultDigestFollowsTheReplacementNotADeletion() throws {
        let inspection = try inspect(replacement: replacement)
        XCTAssertEqual(inspection.replacementText, replacement)
        XCTAssertTrue(inspection.isReplacement)

        let range = (source as NSString).range(of: phrase)
        let replaced = (source as NSString).replacingCharacters(
            in: range,
            with: replacement
        )
        let deleted = (source as NSString).replacingCharacters(in: range, with: "")

        XCTAssertEqual(inspection.expectedResultSHA256, sha256(replaced))
        XCTAssertNotEqual(inspection.expectedResultSHA256, sha256(deleted))
    }

    func testDeletionRemainsTheDefaultAndIsUnchanged() throws {
        let inspection = try inspect(replacement: "")
        let range = (source as NSString).range(of: phrase)
        let deleted = (source as NSString).replacingCharacters(in: range, with: "")

        XCTAssertFalse(inspection.isReplacement)
        XCTAssertEqual(inspection.expectedResultSHA256, sha256(deleted))
        // A deletion still retains no draft-derived text at all.
        XCTAssertFalse(String(reflecting: inspection).contains(source))
        XCTAssertFalse(String(reflecting: inspection).contains(phrase))
    }

    func testReplacementThatChangesNothingIsRefused() throws {
        switch SafeDeleteResponseValidator.parseInspection(
            try inspectData(),
            exactPhrase: phrase,
            expectedProcessIdentifier: 42,
            replacement: phrase
        ) {
        case .success:
            XCTFail("a no-op write must not be authorised")
        case .failure(let error):
            XCTAssertEqual(error, .invalidRange)
        }
    }

    func testDeleteResponseCannotSatisfyAReplacementInspection() throws {
        let inspection = try inspect(replacement: replacement)
        let range = (source as NSString).range(of: phrase)
        let replaced = (source as NSString).replacingCharacters(
            in: range,
            with: replacement
        )

        // A bridge that only knows how to delete would report `delete`. Even
        // with a matching result digest it must not be read as proof that the
        // substitution happened.
        let deleteShaped = try writeData(
            command: "delete",
            flag: "deleted",
            resultValue: replaced,
            range: range
        )
        if case .success = SafeDeleteResponseValidator.validateDeletion(
            deleteShaped,
            against: inspection
        ) {
            XCTFail("a delete response must not validate a replacement")
        }

        let replaceShaped = try writeData(
            command: "replace",
            flag: "replaced",
            resultValue: replaced,
            range: range
        )
        if case .failure(let error) = SafeDeleteResponseValidator.validateDeletion(
            replaceShaped,
            against: inspection
        ) {
            XCTFail("unexpected failure: \(error)")
        }
    }

    func testReplaceResponseCannotSatisfyADeletionInspection() throws {
        let inspection = try inspect(replacement: "")
        let range = (source as NSString).range(of: phrase)
        let deleted = (source as NSString).replacingCharacters(in: range, with: "")

        let replaceShaped = try writeData(
            command: "replace",
            flag: "replaced",
            resultValue: deleted,
            range: range
        )
        if case .success = SafeDeleteResponseValidator.validateDeletion(
            replaceShaped,
            against: inspection
        ) {
            XCTFail("a replace response must not validate a deletion")
        }
    }

    // MARK: - Fixtures

    private enum FixtureError: Error {
        case inspectionRejected(String)
    }

    private func inspect(replacement: String) throws -> SafeDeleteInspection {
        let result = SafeDeleteResponseValidator.parseInspection(
            try inspectData(),
            exactPhrase: phrase,
            expectedProcessIdentifier: 42,
            replacement: replacement
        )
        guard case .success(let value) = result else {
            throw FixtureError.inspectionRejected(String(describing: result))
        }
        return value
    }

    private func inspectData() throws -> Data {
        let range = (source as NSString).range(of: phrase)
        return try jsonData([
            "ok": true,
            "valueSHA256": sha256(source),
            "currentValue": source,
            "targetProcessIdentifier": 42,
            "occurrenceCount": 1,
            "utf16Range": ["location": range.location, "length": range.length],
            "targetBounds": ["x": 10, "y": 20, "width": 30, "height": 40],
        ])
    }

    private func writeData(
        command: String,
        flag: String,
        resultValue: String,
        range: NSRange
    ) throws -> Data {
        try jsonData([
            "ok": true,
            "command": command,
            flag: true,
            "valueSHA256": sha256(source),
            "targetProcessIdentifier": 42,
            "occurrenceCount": 1,
            "utf16Range": ["location": range.location, "length": range.length],
            "valuePrecondition": [
                "expectedSHA256": sha256(source),
                "actualSHA256": sha256(source),
            ],
            "resultValue": resultValue,
            "deletionMethod": "selectedText",
        ])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
