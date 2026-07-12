import CryptoKit
import Foundation
import XCTest
@testable import WDSAppCore

final class SafeDeleteTests: XCTestCase {
    func testValidatesInspectAndDeleteWithoutRetainingSourceText() throws {
        let phrase = "아니,"
        let source = "아니, 이거 고치라고."
        let range = (source as NSString).range(of: phrase)
        let inspectData = try jsonData([
            "ok": true,
            "valueSHA256": sha256(source),
            "currentValue": source,
            "targetProcessIdentifier": 42,
            "occurrenceCount": 1,
            "utf16Range": ["location": range.location, "length": range.length],
            "targetBounds": ["x": 10, "y": 20, "width": 30, "height": 40],
        ])

        let inspection: SafeDeleteInspection
        switch SafeDeleteResponseValidator.parseInspection(
            inspectData,
            exactPhrase: phrase,
            expectedProcessIdentifier: 42
        ) {
        case .success(let value):
            inspection = value
        case .failure(let error):
            return XCTFail("unexpected failure: \(error)")
        }

        XCTAssertEqual(inspection.processIdentifier, 42)
        XCTAssertEqual(inspection.rangeLocation, range.location)
        XCTAssertEqual(inspection.rangeLength, range.length)
        XCTAssertFalse(String(reflecting: inspection).contains(source))
        XCTAssertFalse(String(reflecting: inspection).contains(phrase))

        let remainder = (source as NSString).replacingCharacters(in: range, with: "")
        let deleteData = try jsonData([
            "ok": true,
            "command": "delete",
            "deleted": true,
            "valueSHA256": sha256(source),
            "targetProcessIdentifier": 42,
            "occurrenceCount": 1,
            "utf16Range": ["location": range.location, "length": range.length],
            "valuePrecondition": [
                "expectedSHA256": sha256(source),
                "actualSHA256": sha256(source),
            ],
            "resultValue": remainder,
            "deletionMethod": "selectedText",
        ])

        if case .failure(let error) = SafeDeleteResponseValidator.validateDeletion(
            deleteData,
            against: inspection
        ) {
            XCTFail("unexpected failure: \(error)")
        }
    }

    func testRejectsDuplicateEvenWhenBridgeReportsOneOccurrence() throws {
        let phrase = "아니,"
        let source = "아니, 하나 아니, 둘"
        let range = (source as NSString).range(of: phrase)
        let data = try jsonData([
            "ok": true,
            "valueSHA256": sha256(source),
            "currentValue": source,
            "targetProcessIdentifier": 42,
            "occurrenceCount": 1,
            "utf16Range": ["location": range.location, "length": range.length],
            "focusedElementFrame": ["x": 1, "y": 2, "width": 3, "height": 4],
        ])

        XCTAssertEqual(
            failure(of: SafeDeleteResponseValidator.parseInspection(
                data,
                exactPhrase: phrase,
                expectedProcessIdentifier: 42
            )),
            .duplicateTarget
        )
    }

    func testValidatesDeletingTheEntireDraftToAnEmptyValue() throws {
        let source = "씨발"
        let range = NSRange(location: 0, length: (source as NSString).length)
        let inspectData = try jsonData([
            "ok": true,
            "valueSHA256": sha256(source),
            "currentValue": source,
            "targetProcessIdentifier": 42,
            "occurrenceCount": 1,
            "utf16Range": ["location": range.location, "length": range.length],
            "targetBounds": ["x": 10, "y": 20, "width": 44, "height": 24],
        ])

        let inspection = try SafeDeleteResponseValidator.parseInspection(
            inspectData,
            exactPhrase: source,
            expectedProcessIdentifier: 42
        ).get()
        let deleteData = try jsonData([
            "ok": true,
            "command": "delete",
            "deleted": true,
            "valueSHA256": sha256(source),
            "targetProcessIdentifier": 42,
            "occurrenceCount": 1,
            "utf16Range": ["location": range.location, "length": range.length],
            "valuePrecondition": [
                "expectedSHA256": sha256(source),
                "actualSHA256": sha256(source),
            ],
            "resultValue": "",
            "deletionMethod": "wholeValueFallback",
        ])

        XCTAssertNoThrow(
            try SafeDeleteResponseValidator.validateDeletion(deleteData, against: inspection).get()
        )
    }

    func testRejectsChangedDraftDigest() throws {
        let source = "original"
        let data = try jsonData([
            "ok": true,
            "valueSHA256": sha256(source),
            "currentValue": "changed",
            "targetProcessIdentifier": 42,
            "occurrenceCount": 1,
            "utf16Range": ["location": 0, "length": 8],
            "focusedElementFrame": ["x": 1, "y": 2, "width": 3, "height": 4],
        ])

        XCTAssertEqual(
            failure(of: SafeDeleteResponseValidator.parseInspection(
                data,
                exactPhrase: source,
                expectedProcessIdentifier: 42
            )),
            .invalidDigest
        )
    }

    func testRejectsDeleteResponseWithWrongResult() throws {
        let inspection = SafeDeleteInspection(
            valueSHA256: String(repeating: "a", count: 64),
            expectedResultSHA256: sha256("expected"),
            processIdentifier: 42,
            rangeLocation: 0,
            rangeLength: 1,
            overlayRectangle: OverlayRectangle(x: 1, y: 2, width: 3, height: 4)
        )
        let data = try jsonData([
            "ok": true,
            "command": "delete",
            "deleted": true,
            "valueSHA256": inspection.valueSHA256,
            "targetProcessIdentifier": 42,
            "occurrenceCount": 1,
            "utf16Range": ["location": 0, "length": 1],
            "valuePrecondition": [
                "expectedSHA256": inspection.valueSHA256,
                "actualSHA256": inspection.valueSHA256,
            ],
            "resultValue": "wrong",
            "deletionMethod": "wholeValueFallback",
        ])

        XCTAssertEqual(
            failure(of: SafeDeleteResponseValidator.validateDeletion(data, against: inspection)),
            .deleteNotVerified
        )
    }

    private func failure<Success>(
        of result: Result<Success, SafeDeleteFailure>
    ) -> SafeDeleteFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
