import CoreFoundation
import Foundation

public struct OverlayRenderReport: Equatable, Sendable {
    public let framesDrawn: Int
    public let glyphFramesDrawn: Int
    public let timerTicks: Int
    public let durationMilliseconds: Int
    public let elapsedMilliseconds: Int
    public let windowVisibleAtStart: Bool
    public let targetIntersectsScreen: Bool
    public let glyphContentRendered: Bool
    public let fallbackUsed: Bool

    public init(
        framesDrawn: Int,
        glyphFramesDrawn: Int,
        timerTicks: Int,
        durationMilliseconds: Int,
        elapsedMilliseconds: Int,
        windowVisibleAtStart: Bool,
        targetIntersectsScreen: Bool,
        glyphContentRendered: Bool,
        fallbackUsed: Bool
    ) {
        self.framesDrawn = framesDrawn
        self.glyphFramesDrawn = glyphFramesDrawn
        self.timerTicks = timerTicks
        self.durationMilliseconds = durationMilliseconds
        self.elapsedMilliseconds = elapsedMilliseconds
        self.windowVisibleAtStart = windowVisibleAtStart
        self.targetIntersectsScreen = targetIntersectsScreen
        self.glyphContentRendered = glyphContentRendered
        self.fallbackUsed = fallbackUsed
    }
}

public enum OverlayRenderReportFailure: Error, Equatable, Sendable {
    case invalidPayload
    case invalidSchema
    case incomplete
    case durationMismatch
    case elapsedOutOfRange
    case windowNotVisible
    case targetOffscreen
    case noFramesDrawn
    case noGlyphContent
    case noTimerTicks
}

public enum OverlayRenderReportCodec {
    public static let schema = "wds.overlay-report.v2"
    private static let maximumPayloadSize = 4 * 1_024
    private static let expectedKeys: Set<String> = [
        "schema",
        "completed",
        "framesDrawn",
        "glyphFramesDrawn",
        "timerTicks",
        "durationMs",
        "elapsedMs",
        "windowVisibleAtStart",
        "targetIntersectsScreen",
        "glyphContentRendered",
        "fallbackUsed",
    ]

    public static func encode(_ report: OverlayRenderReport) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema": schema,
            "completed": true,
            "framesDrawn": report.framesDrawn,
            "glyphFramesDrawn": report.glyphFramesDrawn,
            "timerTicks": report.timerTicks,
            "durationMs": report.durationMilliseconds,
            "elapsedMs": report.elapsedMilliseconds,
            "windowVisibleAtStart": report.windowVisibleAtStart,
            "targetIntersectsScreen": report.targetIntersectsScreen,
            "glyphContentRendered": report.glyphContentRendered,
            "fallbackUsed": report.fallbackUsed,
        ])
    }

    public static func parse(
        _ data: Data,
        expectedDurationMilliseconds: Int
    ) -> Result<OverlayRenderReport, OverlayRenderReportFailure> {
        guard !data.isEmpty,
              data.count <= maximumPayloadSize,
              (100...10_000).contains(expectedDurationMilliseconds),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expectedKeys
        else {
            return .failure(.invalidPayload)
        }

        guard object["schema"] as? String == schema else {
            return .failure(.invalidSchema)
        }
        guard boolean(object["completed"]) == true else {
            return .failure(.incomplete)
        }
        guard let duration = integer(object["durationMs"]),
              duration == expectedDurationMilliseconds
        else {
            return .failure(.durationMismatch)
        }
        guard let elapsed = integer(object["elapsedMs"]),
              elapsed >= max(50, Int(Double(expectedDurationMilliseconds) * 0.75)),
              elapsed <= expectedDurationMilliseconds + 5_000
        else {
            return .failure(.elapsedOutOfRange)
        }
        guard boolean(object["windowVisibleAtStart"]) == true else {
            return .failure(.windowNotVisible)
        }
        guard boolean(object["targetIntersectsScreen"]) == true else {
            return .failure(.targetOffscreen)
        }
        guard let framesDrawn = integer(object["framesDrawn"]),
              (1...10_000).contains(framesDrawn)
        else {
            return .failure(.noFramesDrawn)
        }
        guard boolean(object["glyphContentRendered"]) == true,
              let glyphFramesDrawn = integer(object["glyphFramesDrawn"]),
              (1...framesDrawn).contains(glyphFramesDrawn)
        else {
            return .failure(.noGlyphContent)
        }
        guard let fallbackUsed = boolean(object["fallbackUsed"]) else {
            return .failure(.invalidPayload)
        }
        guard let timerTicks = integer(object["timerTicks"]),
              (1...10_000).contains(timerTicks)
        else {
            return .failure(.noTimerTicks)
        }

        return .success(OverlayRenderReport(
            framesDrawn: framesDrawn,
            glyphFramesDrawn: glyphFramesDrawn,
            timerTicks: timerTicks,
            durationMilliseconds: duration,
            elapsedMilliseconds: elapsed,
            windowVisibleAtStart: true,
            targetIntersectsScreen: true,
            glyphContentRendered: true,
            fallbackUsed: fallbackUsed
        ))
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max)
        else { return nil }
        return Int(double)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }
}
