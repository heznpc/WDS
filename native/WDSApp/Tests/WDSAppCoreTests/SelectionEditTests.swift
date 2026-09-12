import CryptoKit
import Foundation
import XCTest
@testable import WDSAppCore

final class SelectionEditTests: XCTestCase {
    func testEmptyInputAcceptsOnlyExplicitInsertionAndTextStaysOutOfArgv() throws {
        let data = try fixture(value: "", target: "", range: NSRange(location: 0, length: 0))
        let result = SafeDeleteResponseValidator.parseInspection(data, exactPhrase: "", expectedProcessIdentifier: 42,
            replacement: "다른 세션의 의견\n", selectionOnly: true)
        let inspection = try result.get()
        XCTAssertEqual(inspection.rangeLength, 0)
        XCTAssertTrue(inspection.selectionOnly)
        XCTAssertFalse(inspection.bridgeArguments(bundleIdentifier: "test.app").joined().contains("다른 세션"))
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: inspection.bridgeInput(target: "")) as? [String: String])
        XCTAssertEqual(payload["replacement"], "다른 세션의 의견\n")
        XCTAssertEqual(payload["target"], "")
        XCTAssertThrowsError(try SafeDeleteResponseValidator.parseInspection(data, exactPhrase: "", expectedProcessIdentifier: 42,
            replacement: "other").get())
    }

    func testAnExplicitSelectedOccurrenceCanDisambiguateRepeatedText() throws {
        let data = try fixture(value: "same same", target: "same", range: NSRange(location: 5, length: 4))
        let selected = try SafeDeleteResponseValidator.parseInspection(data, exactPhrase: "same", expectedProcessIdentifier: 42,
            replacement: "quoted", selectionOnly: true).get()
        XCTAssertEqual(selected.rangeLocation, 5)
        XCTAssertThrowsError(try SafeDeleteResponseValidator.parseInspection(data, exactPhrase: "same", expectedProcessIdentifier: 42,
            replacement: "quoted").get())
    }

    func testSelectionRejectsMalformedRangeWrongTargetAndWrongCommand() throws {
        let bad = [
            try fixture(value: "abc", target: "x", range: NSRange(location: 1, length: 1)),
            try fixture(value: "abc", target: "", range: NSRange(location: 5, length: 0)),
            try fixture(value: "😀", target: "", range: NSRange(location: 1, length: 0)),
            try fixture(value: "abc", target: "", range: NSRange(location: 0, length: 0), command: "inspect"),
        ]
        for data in bad {
            XCTAssertThrowsError(try SafeDeleteResponseValidator.parseInspection(data, exactPhrase: "", expectedProcessIdentifier: 42,
                replacement: "quote", selectionOnly: true).get())
        }
    }

    private func fixture(value: String, target: String, range: NSRange, command: String = "inspect-selection") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "ok": true, "command": command, "target": target,
            "currentValue": value,
            "valueSHA256": SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined(),
            "targetProcessIdentifier": 42, "occurrenceCount": 1,
            "utf16Range": ["location": range.location, "length": range.length],
            "focusedElementFrame": ["x": 10, "y": 20, "width": 400, "height": 100],
        ])
    }
}
