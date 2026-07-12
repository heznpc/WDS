import XCTest
@testable import WDSAppCore

final class OverlayGeometryResolverTests: XCTestCase {
    func testUsesExactRangeBoundsWithoutEstimation() throws {
        let exact = OverlayRectangle(x: 40, y: 50, width: 44, height: 24)
        let result = try XCTUnwrap(OverlayGeometryResolver.resolve(
            exactBounds: exact,
            focusedElementFrame: OverlayRectangle(x: 10, y: 20, width: 600, height: 120),
            currentValue: "씨발 다시 설명해 주세요",
            target: "씨발",
            utf16Location: 0,
            utf16Length: 2
        ))
        XCTAssertEqual(result.rectangle, exact)
        XCTAssertFalse(result.isEstimated)
    }

    func testElectronFallbackStaysCompactAndTracksPrefixPosition() throws {
        let result = try XCTUnwrap(OverlayGeometryResolver.resolve(
            exactBounds: nil,
            focusedElementFrame: OverlayRectangle(x: 100, y: 200, width: 720, height: 160),
            currentValue: "앞 문장 씨발 뒤 문장",
            target: "씨발",
            utf16Location: 5,
            utf16Length: 2
        ))
        XCTAssertTrue(result.isEstimated)
        XCTAssertLessThanOrEqual(result.rectangle.width, 24)
        XCTAssertLessThanOrEqual(result.rectangle.height, 32)
        XCTAssertGreaterThan(result.rectangle.x, 100)
        XCTAssertGreaterThanOrEqual(result.rectangle.y, 200)
    }

    func testRejectsARangeThatDoesNotIdentifyTheTarget() {
        XCTAssertNil(OverlayGeometryResolver.resolve(
            exactBounds: nil,
            focusedElementFrame: OverlayRectangle(x: 0, y: 0, width: 400, height: 80),
            currentValue: "안전한 문장",
            target: "씨발",
            utf16Location: 0,
            utf16Length: 2
        ))
    }
}
