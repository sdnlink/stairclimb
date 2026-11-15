import XCTest
@testable import StairClimb

final class StepRulesTests: XCTestCase {
    func testRequiredFloorAndRemainingBoundaries() throws {
        for (steps, floor, remaining) in [(0, 0, 100), (99, 0, 1), (100, 1, 100), (101, 1, 99),
                                            (999, 9, 1), (1000, 10, 100), (1_000_000, 10_000, 100)] {
            let value = try StepRules.progress(steps: steps)
            XCTAssertEqual(value.floor, floor, "steps=\(steps)")
            XCTAssertEqual(value.remainingSteps, remaining, "steps=\(steps)")
        }
    }

    func testRejectsInvalidIntegerRange() {
        for value in [-1, Int.min, 1_000_001, Int.max] {
            XCTAssertThrowsError(try StepRules.progress(steps: value))
        }
    }

    func testHealthQuantitiesAreFiniteAndNotSilentlyClamped() throws {
        XCTAssertEqual(try StepRules.healthProgress(total: 101.9).steps, 101)
        for value in [-0.1, Double.nan, Double.infinity, -Double.infinity, 1_000_000.1] {
            XCTAssertThrowsError(try StepRules.healthProgress(total: value))
        }
    }

    func testProgressToNextFloor() throws {
        XCTAssertEqual(try StepRules.progress(steps: 0).fraction, 0)
        XCTAssertEqual(try StepRules.progress(steps: 99).fraction, 0.99)
        XCTAssertEqual(try StepRules.progress(steps: 100).fraction, 0)
    }
}
