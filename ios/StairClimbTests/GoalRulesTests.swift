import XCTest
@testable import StairClimb

final class GoalRulesTests: XCTestCase {
    func testUnknownStepsStayUnknownAtBothTargetLimits() throws {
        for target in [100, StepRules.maximumSteps] {
            let progress = try GoalRules.evaluate(target: target, steps: nil)

            XCTAssertEqual(progress.target, target)
            XCTAssertNil(progress.steps)
            XCTAssertNil(progress.fraction)
            XCTAssertNil(progress.remainingSteps)
            XCTAssertNil(progress.isComplete)
        }
    }

    func testMeasuredZeroIsKnownAndIncompleteAtBothTargetLimits() throws {
        for target in [100, StepRules.maximumSteps] {
            let progress = try GoalRules.evaluate(target: target, steps: 0)

            XCTAssertEqual(progress.target, target)
            XCTAssertEqual(progress.steps, 0)
            XCTAssertEqual(progress.fraction, 0)
            XCTAssertEqual(progress.remainingSteps, target)
            XCTAssertEqual(progress.isComplete, false)
            XCTAssertNotEqual(progress, try GoalRules.evaluate(target: target, steps: nil))
        }
    }

    func testOneStepBeforeTargetIsStillIncomplete() throws {
        let progress = try GoalRules.evaluate(target: 100, steps: 99)

        XCTAssertEqual(progress.target, 100)
        XCTAssertEqual(progress.steps, 99)
        XCTAssertEqual(try XCTUnwrap(progress.fraction), 0.99, accuracy: 0.000_001)
        XCTAssertEqual(progress.remainingSteps, 1)
        XCTAssertEqual(progress.isComplete, false)
    }

    func testExactAndExcessCompletionClampProgressButPreserveRealSteps() throws {
        for steps in [100, 101, StepRules.maximumSteps] {
            let progress = try GoalRules.evaluate(target: 100, steps: steps)

            XCTAssertEqual(progress.target, 100)
            XCTAssertEqual(progress.steps, steps)
            XCTAssertEqual(progress.fraction, 1)
            XCTAssertEqual(progress.remainingSteps, 0)
            XCTAssertEqual(progress.isComplete, true)
            XCTAssertLessThanOrEqual(try XCTUnwrap(progress.fraction), 1)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(progress.remainingSteps), 0)
        }
    }

    func testMaximumTargetAcceptsPartialAndMaximumSteps() throws {
        let halfway = try GoalRules.evaluate(target: StepRules.maximumSteps,
                                             steps: StepRules.maximumSteps / 2)
        XCTAssertEqual(halfway.target, StepRules.maximumSteps)
        XCTAssertEqual(halfway.steps, StepRules.maximumSteps / 2)
        XCTAssertEqual(halfway.fraction, 0.5)
        XCTAssertEqual(halfway.remainingSteps, StepRules.maximumSteps / 2)
        XCTAssertEqual(halfway.isComplete, false)

        let complete = try GoalRules.evaluate(target: StepRules.maximumSteps,
                                              steps: StepRules.maximumSteps)
        XCTAssertEqual(complete.target, StepRules.maximumSteps)
        XCTAssertEqual(complete.steps, StepRules.maximumSteps)
        XCTAssertEqual(complete.fraction, 1)
        XCTAssertEqual(complete.remainingSteps, 0)
        XCTAssertEqual(complete.isComplete, true)
    }

    func testInvalidTargetsThrowExplicitTargetErrorEvenWhenStepsAreUnknown() {
        let readings: [Int?] = [nil, 0, StepRules.maximumSteps]
        for target in [Int.min, -1, 0, 99, StepRules.maximumSteps + 1, Int.max] {
            for steps in readings {
                XCTAssertThrowsError(try GoalRules.evaluate(target: target, steps: steps),
                                     "target=\(target), steps=\(String(describing: steps))") { error in
                    XCTAssertEqual(error as? GoalRules.ValidationError, .invalidTarget)
                }
            }
        }
    }

    func testInvalidStepsThrowExplicitStepsErrorAtBothTargetLimits() {
        for target in [100, StepRules.maximumSteps] {
            for steps in [Int.min, -1, StepRules.maximumSteps + 1, Int.max] {
                XCTAssertThrowsError(try GoalRules.evaluate(target: target, steps: steps),
                                     "target=\(target), steps=\(steps)") { error in
                    XCTAssertEqual(error as? GoalRules.ValidationError, .invalidSteps)
                }
            }
        }
    }
}
