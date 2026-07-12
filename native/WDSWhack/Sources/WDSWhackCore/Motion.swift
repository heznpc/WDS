import Foundation

public enum MotionDirection: String, CaseIterable, Sendable {
    case stationary
    case north
    case northeast
    case east
    case southeast
    case south
    case southwest
    case west
    case northwest

    /// Unit vector in an AppKit view, whose positive y-axis points upward.
    /// CLI direction names describe Quartz's top-left coordinate space, so
    /// their y component is inverted here at the boundary.
    public var appKitUnitVector: MotionVector {
        let diagonal = 1 / (2.0).squareRoot()
        switch self {
        case .stationary:
            return MotionVector(x: 0, y: 0)
        case .north:
            return MotionVector(x: 0, y: 1)
        case .northeast:
            return MotionVector(x: diagonal, y: diagonal)
        case .east:
            return MotionVector(x: 1, y: 0)
        case .southeast:
            return MotionVector(x: diagonal, y: -diagonal)
        case .south:
            return MotionVector(x: 0, y: -1)
        case .southwest:
            return MotionVector(x: -diagonal, y: -diagonal)
        case .west:
            return MotionVector(x: -1, y: 0)
        case .northwest:
            return MotionVector(x: -diagonal, y: diagonal)
        }
    }
}

public struct MotionVector: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MotionSample: Equatable, Sendable {
    public static let maximumSpeed = 4_000.0
    public static let maximumDistance = 1_200.0
    public static let stationary = MotionSample(direction: .stationary, speed: 0, distance: 0)

    public let direction: MotionDirection
    public let speed: Double
    public let distance: Double

    public init(direction: MotionDirection, speed: Double, distance: Double) {
        self.direction = direction
        self.speed = Self.clamp(speed, to: 0...Self.maximumSpeed)
        self.distance = Self.clamp(distance, to: 0...Self.maximumDistance)
    }

    public var appKitUnitVector: MotionVector {
        direction.appKitUnitVector
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
