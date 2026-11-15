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

final class StaircaseRulesTests: XCTestCase {
    func testCrossingOneFloorAndFractionOnlyUpdates() {
        XCTAssertEqual(StaircaseRules.route(from: 81, to: 82, replay: false, animated: true), [81, 82])
        XCTAssertEqual(StaircaseRules.route(from: 82, to: 82, replay: false, animated: true), [82])
    }

    func testLargeCatchupIsBoundedAndEndsAtTrueFloor() {
        let route = StaircaseRules.route(from: 0, to: 10_000, replay: false, animated: true)
        XCTAssertEqual(route, Array(9_992...10_000))
        XCTAssertEqual(route.count, 9)
    }

    func testFirstReadNewDayAndDownwardCorrectionDoNotAnimate() {
        XCTAssertEqual(StaircaseRules.route(from: nil, to: 82, replay: false, animated: true), [82])
        XCTAssertEqual(StaircaseRules.route(from: nil, to: 0, replay: false, animated: true), [0])
        XCTAssertEqual(StaircaseRules.route(from: 82, to: 2, replay: false, animated: true), [2])
    }

    func testReduceMotionAndStaleDataSettleImmediately() {
        XCTAssertEqual(StaircaseRules.route(from: 10, to: 82, replay: false, animated: false), [82])
        XCTAssertEqual(StaircaseRules.route(from: 82, to: 82, replay: true, animated: false), [82])
    }

    func testReplayShowsOnlyAlreadyCompletedFloors() {
        XCTAssertEqual(StaircaseRules.route(from: 82, to: 82, replay: true, animated: true), Array(78...82))
        XCTAssertEqual(StaircaseRules.route(from: 1, to: 1, replay: true, animated: true), [0, 1])
        XCTAssertEqual(StaircaseRules.route(from: 0, to: 0, replay: true, animated: true), [0])
    }

    func testBrowsingStaysWithinValidFloorWindows() {
        XCTAssertEqual(StaircaseRules.centeredBase(0), 0)
        XCTAssertEqual(StaircaseRules.centeredBase(82), 80)
        XCTAssertEqual(StaircaseRules.centeredBase(10_000), 9_996)
        XCTAssertEqual(StaircaseRules.browse(base: 0, delta: -3, near: 0), 0)
        XCTAssertEqual(StaircaseRules.browse(base: 83, delta: 3, near: 82), 83)
        XCTAssertEqual(StaircaseRules.browse(base: 9_996, delta: 3, near: 10_000), 9_996)
    }

    func testInteractivePresentationDoesNotChangeAuthoritativeProgress() throws {
        let progress = try StepRules.progress(steps: 8_246)
        _ = StaircaseRules.route(from: 0, to: progress.floor, replay: true, animated: true)
        _ = StaircaseRules.browse(base: 80, delta: 3, near: progress.floor)
        XCTAssertEqual(progress.steps, 8_246)
        XCTAssertEqual(progress.floor, 82)
        XCTAssertEqual(progress.remainingSteps, 54)
    }
}
