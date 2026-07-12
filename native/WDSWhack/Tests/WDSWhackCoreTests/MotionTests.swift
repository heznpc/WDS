import XCTest
@testable import WDSWhackCore

final class MotionTests: XCTestCase {
    func testQuartzDirectionsMapToAppKitCoordinates() {
        let diagonal = 1 / (2.0).squareRoot()
        let expected: [MotionDirection: MotionVector] = [
            .stationary: MotionVector(x: 0, y: 0),
            .north: MotionVector(x: 0, y: 1),
            .northeast: MotionVector(x: diagonal, y: diagonal),
            .east: MotionVector(x: 1, y: 0),
            .southeast: MotionVector(x: diagonal, y: -diagonal),
            .south: MotionVector(x: 0, y: -1),
            .southwest: MotionVector(x: -diagonal, y: -diagonal),
            .west: MotionVector(x: -1, y: 0),
            .northwest: MotionVector(x: -diagonal, y: diagonal),
        ]

        for (direction, vector) in expected {
            XCTAssertEqual(direction.appKitUnitVector.x, vector.x, accuracy: 0.000_001)
            XCTAssertEqual(direction.appKitUnitVector.y, vector.y, accuracy: 0.000_001)
        }
    }

    func testMotionValuesAreClamped() {
        let negative = MotionSample(direction: .east, speed: -20, distance: -4)
        XCTAssertEqual(negative.speed, 0)
        XCTAssertEqual(negative.distance, 0)

        let excessive = MotionSample(direction: .west, speed: 90_000, distance: 80_000)
        XCTAssertEqual(excessive.speed, MotionSample.maximumSpeed)
        XCTAssertEqual(excessive.distance, MotionSample.maximumDistance)
    }

    func testStationaryDirectionHasZeroVector() {
        let sample = MotionSample(direction: .stationary, speed: 2_000, distance: 400)
        XCTAssertEqual(sample.appKitUnitVector, MotionVector(x: 0, y: 0))
    }

    func testOmittedMotionDefaultsAreStationary() {
        XCTAssertEqual(MotionSample.stationary.speed, 0)
        XCTAssertEqual(MotionSample.stationary.distance, 0)
        XCTAssertEqual(MotionSample.stationary.direction, .stationary)
    }
}
