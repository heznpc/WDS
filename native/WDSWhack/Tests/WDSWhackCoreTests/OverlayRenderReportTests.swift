import Foundation
import XCTest
@testable import WDSWhackCore

final class OverlayRenderReportTests: XCTestCase {
    func testRoundTripsCompletedVisibleRenderWithFrames() throws {
        let report = OverlayRenderReport(
            framesDrawn: 94,
            glyphFramesDrawn: 81,
            timerTicks: 96,
            durationMilliseconds: 1_600,
            elapsedMilliseconds: 1_608,
            windowVisibleAtStart: true,
            targetIntersectsScreen: true,
            glyphContentRendered: true,
            fallbackUsed: false
        )

        XCTAssertEqual(
            try OverlayRenderReportCodec.parse(
                OverlayRenderReportCodec.encode(report),
                expectedDurationMilliseconds: 1_600
            ).get(),
            report
        )
    }

    func testRejectsMissingOrExtraFields() throws {
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(removing: "framesDrawn"),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.invalidPayload)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(extra: ["targetText": "never allowed"]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.invalidPayload)
        )
    }

    func testRejectsWrongSchemaAndDuration() throws {
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["schema": "wds.overlay-report.v0"]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.invalidSchema)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["durationMs": 900]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.durationMismatch)
        )
    }

    func testRejectsImplausibleElapsedTimeOrMissingTimerTicks() throws {
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["elapsedMs": 12]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.elapsedOutOfRange)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["timerTicks": 0]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.noTimerTicks)
        )
    }

    func testRejectsAReportWithoutRenderedGlyphContent() throws {
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["glyphContentRendered": false]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.noGlyphContent)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["glyphFramesDrawn": 0]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.noGlyphContent)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["glyphFramesDrawn": 95]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.noGlyphContent)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["glyphFramesDrawn": true]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.noGlyphContent)
        )
    }

    func testFallbackFlagMustBeBooleanAndRoundTrips() throws {
        let fallback = OverlayRenderReport(
            framesDrawn: 94,
            glyphFramesDrawn: 81,
            timerTicks: 96,
            durationMilliseconds: 1_600,
            elapsedMilliseconds: 1_608,
            windowVisibleAtStart: true,
            targetIntersectsScreen: true,
            glyphContentRendered: true,
            fallbackUsed: true
        )
        XCTAssertEqual(
            try OverlayRenderReportCodec.parse(
                OverlayRenderReportCodec.encode(fallback),
                expectedDurationMilliseconds: 1_600
            ).get(),
            fallback
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["fallbackUsed": 0]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.invalidPayload)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(removing: "fallbackUsed"),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.invalidPayload)
        )
    }

    func testRejectsInvisibleIncompleteOrZeroFrameRender() throws {
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["windowVisibleAtStart": false]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.windowNotVisible)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["targetIntersectsScreen": false]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.targetOffscreen)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["completed": false]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.incomplete)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["framesDrawn": 0]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.noFramesDrawn)
        )
    }

    func testRejectsBooleanNumbersAndOversizedPayloads() throws {
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                try payload(overrides: ["framesDrawn": true]),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.noFramesDrawn)
        )
        XCTAssertEqual(
            OverlayRenderReportCodec.parse(
                Data(repeating: 0x20, count: 4_097),
                expectedDurationMilliseconds: 1_600
            ),
            .failure(.invalidPayload)
        )
    }

    private func payload(
        overrides: [String: Any] = [:],
        removing keyToRemove: String? = nil,
        extra: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = [
            "schema": OverlayRenderReportCodec.schema,
            "completed": true,
            "framesDrawn": 94,
            "glyphFramesDrawn": 81,
            "timerTicks": 96,
            "durationMs": 1_600,
            "elapsedMs": 1_608,
            "windowVisibleAtStart": true,
            "targetIntersectsScreen": true,
            "glyphContentRendered": true,
            "fallbackUsed": false,
        ]
        overrides.forEach { object[$0.key] = $0.value }
        extra.forEach { object[$0.key] = $0.value }
        if let keyToRemove {
            object.removeValue(forKey: keyToRemove)
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
