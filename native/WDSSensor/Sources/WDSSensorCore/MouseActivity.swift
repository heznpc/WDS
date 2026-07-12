import Foundation

public enum MouseSampleKind: String, Sendable {
    case move
    case drag
    case click
    case scroll
}

public struct MouseSample: Sendable {
    public let timestampMilliseconds: Double
    public let kind: MouseSampleKind
    public let x: Double?
    public let y: Double?
    public let scrollX: Double
    public let scrollY: Double

    public init(
        timestampMilliseconds: Double,
        kind: MouseSampleKind,
        x: Double? = nil,
        y: Double? = nil,
        scrollX: Double = 0,
        scrollY: Double = 0
    ) {
        self.timestampMilliseconds = timestampMilliseconds
        self.kind = kind
        self.x = x
        self.y = y
        self.scrollX = scrollX
        self.scrollY = scrollY
    }
}

public struct MouseActivitySummary: Equatable, Sendable {
    public let windowMilliseconds: Double
    public let eventCount: Int
    public let movementCount: Int
    public let clickCount: Int
    public let scrollEventCount: Int
    public let distancePoints: Double
    public let averageSpeedPointsPerSecond: Double
    public let direction: String
    public let scrollX: Double
    public let scrollY: Double

    public init(
        windowMilliseconds: Double,
        eventCount: Int,
        movementCount: Int,
        clickCount: Int,
        scrollEventCount: Int,
        distancePoints: Double,
        averageSpeedPointsPerSecond: Double,
        direction: String,
        scrollX: Double,
        scrollY: Double
    ) {
        self.windowMilliseconds = windowMilliseconds
        self.eventCount = eventCount
        self.movementCount = movementCount
        self.clickCount = clickCount
        self.scrollEventCount = scrollEventCount
        self.distancePoints = distancePoints
        self.averageSpeedPointsPerSecond = averageSpeedPointsPerSecond
        self.direction = direction
        self.scrollX = scrollX
        self.scrollY = scrollY
    }
}

/// A bounded, memory-only buffer. Callers receive aggregate motion features; the
/// individual samples are intentionally not exposed by this type.
public struct MouseActivityRing: Sendable {
    public let capacity: Int
    public let windowMilliseconds: Double

    private var samples: [MouseSample] = []

    public init(capacity: Int = 4_096, windowMilliseconds: Double) {
        precondition(capacity > 0)
        precondition(windowMilliseconds > 0)
        self.capacity = capacity
        self.windowMilliseconds = windowMilliseconds
        samples.reserveCapacity(min(capacity, 4_096))
    }

    public var count: Int { samples.count }

    public mutating func removeAll() {
        samples.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ sample: MouseSample) {
        samples.append(sample)
        prune(nowMilliseconds: sample.timestampMilliseconds)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public mutating func summary(nowMilliseconds: Double) -> MouseActivitySummary {
        prune(nowMilliseconds: nowMilliseconds)

        var movement: [MouseSample] = []
        var clickCount = 0
        var scrollEventCount = 0
        var scrollX = 0.0
        var scrollY = 0.0

        for sample in samples {
            switch sample.kind {
            case .move, .drag:
                if sample.x != nil, sample.y != nil {
                    movement.append(sample)
                }
            case .click:
                clickCount += 1
            case .scroll:
                scrollEventCount += 1
                scrollX += sample.scrollX
                scrollY += sample.scrollY
            }
        }

        var distance = 0.0
        if movement.count > 1 {
            for index in 1..<movement.count {
                guard
                    let previousX = movement[index - 1].x,
                    let previousY = movement[index - 1].y,
                    let currentX = movement[index].x,
                    let currentY = movement[index].y
                else { continue }
                distance += hypot(currentX - previousX, currentY - previousY)
            }
        }

        let motionDurationMilliseconds: Double
        if let first = movement.first, let last = movement.last {
            motionDurationMilliseconds = max(0, last.timestampMilliseconds - first.timestampMilliseconds)
        } else {
            motionDurationMilliseconds = 0
        }
        let speed = motionDurationMilliseconds > 0
            ? distance / (motionDurationMilliseconds / 1_000)
            : 0

        let direction: String
        if
            let first = movement.first,
            let last = movement.last,
            let firstX = first.x,
            let firstY = first.y,
            let lastX = last.x,
            let lastY = last.y
        {
            direction = Self.direction(dx: lastX - firstX, dy: lastY - firstY)
        } else {
            direction = "stationary"
        }

        return MouseActivitySummary(
            windowMilliseconds: windowMilliseconds,
            eventCount: samples.count,
            movementCount: movement.count,
            clickCount: clickCount,
            scrollEventCount: scrollEventCount,
            distancePoints: distance,
            averageSpeedPointsPerSecond: speed,
            direction: direction,
            scrollX: scrollX,
            scrollY: scrollY
        )
    }

    private mutating func prune(nowMilliseconds: Double) {
        let cutoff = nowMilliseconds - windowMilliseconds
        if let firstRetained = samples.firstIndex(where: { $0.timestampMilliseconds >= cutoff }) {
            if firstRetained > 0 {
                samples.removeFirst(firstRetained)
            }
        } else {
            samples.removeAll(keepingCapacity: true)
        }
    }

    private static func direction(dx: Double, dy: Double) -> String {
        guard hypot(dx, dy) >= 1 else { return "stationary" }

        // Quartz global coordinates grow downward, so positive y means south.
        let angle = atan2(dy, dx)
        let sector = Int(round(angle / (.pi / 4)))
        switch sector {
        case 0:
            return "east"
        case 1:
            return "southeast"
        case 2:
            return "south"
        case 3:
            return "southwest"
        case 4, -4:
            return "west"
        case -3:
            return "northwest"
        case -2:
            return "north"
        case -1:
            return "northeast"
        default:
            return "stationary"
        }
    }
}
