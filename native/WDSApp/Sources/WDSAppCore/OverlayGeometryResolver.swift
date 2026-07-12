import Foundation

public struct OverlayGeometryResolution: Equatable, Sendable {
    public let rectangle: OverlayRectangle
    public let isEstimated: Bool

    public init(rectangle: OverlayRectangle, isEstimated: Bool) {
        self.rectangle = rectangle
        self.isEstimated = isEstimated
    }
}

public enum OverlayGeometryResolver {
    public static func resolve(
        exactBounds: OverlayRectangle?,
        focusedElementFrame: OverlayRectangle?,
        currentValue: String,
        target: String,
        utf16Location: Int,
        utf16Length: Int
    ) -> OverlayGeometryResolution? {
        guard !target.isEmpty,
              utf16Location >= 0,
              utf16Length > 0,
              utf16Location <= Int.max - utf16Length
        else { return nil }

        let source = currentValue as NSString
        let range = NSRange(location: utf16Location, length: utf16Length)
        guard NSMaxRange(range) <= source.length,
              utf16Length == (target as NSString).length,
              source.substring(with: range) == target
        else { return nil }

        if let exactBounds, isUsable(exactBounds) {
            return OverlayGeometryResolution(rectangle: exactBounds, isEstimated: false)
        }
        guard let frame = focusedElementFrame, isUsable(frame) else { return nil }

        let horizontalInset = min(frame.width / 4, clamp(frame.width * 0.025, 5, 12))
        let verticalInset = min(frame.height / 4, clamp(frame.height * 0.14, 3, 10))
        let usableWidth = max(1, frame.width - horizontalInset * 2)
        let usableHeight = max(1, frame.height - verticalInset * 2)
        let prefix = source.substring(to: utf16Location)
        let prefixGraphemes = String(prefix).count
        let targetGraphemes = max(1, target.count)
        let allGraphemes = max(1, currentValue.count)
        let glyphWidth = clamp(usableWidth / Double(allGraphemes), 6, 12)
        let minimumTargetWidth = min(18, usableWidth)
        let estimatedX = horizontalInset + Double(prefixGraphemes) * glyphWidth
        let localX = clamp(
            estimatedX,
            horizontalInset,
            max(horizontalInset, frame.width - horizontalInset - minimumTargetWidth)
        )
        let availableWidth = max(1, frame.width - horizontalInset - localX)
        let width = min(
            availableWidth,
            max(minimumTargetWidth, Double(targetGraphemes) * glyphWidth)
        )
        let height = min(32, usableHeight)
        let estimated = OverlayRectangle(
            x: frame.x + localX,
            y: frame.y + verticalInset,
            width: width,
            height: height
        )
        return OverlayGeometryResolution(rectangle: estimated, isEstimated: true)
    }

    private static func isUsable(_ rectangle: OverlayRectangle) -> Bool {
        rectangle.x.isFinite && rectangle.y.isFinite
            && rectangle.width.isFinite && rectangle.height.isFinite
            && rectangle.width > 0 && rectangle.height > 0
            && rectangle.width <= 10_000 && rectangle.height <= 10_000
            && abs(rectangle.x) <= 100_000 && abs(rectangle.y) <= 100_000
    }

    private static func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}
