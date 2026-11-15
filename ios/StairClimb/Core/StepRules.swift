import Foundation

enum StepRules {
    static let stepsPerFloor = 100
    static let maximumSteps = 1_000_000
    // Product default shared with backend/domain.py; used by the later circle UI.
    static let circleBandSteps = 1_000

    enum ValidationError: Error { case outOfRange }

    static func progress(steps: Int) throws -> StepProgress {
        guard (0...maximumSteps).contains(steps) else { throw ValidationError.outOfRange }
        return StepProgress(steps: steps)
    }

    static func healthProgress(total: Double) throws -> StepProgress {
        guard total.isFinite, total >= 0, total <= Double(maximumSteps) else {
            throw ValidationError.outOfRange
        }
        // HealthKit quantities are Double. Publish whole cumulative steps, never round up.
        return try progress(steps: Int(total.rounded(.down)))
    }
}

struct StepProgress: Equatable {
    let steps: Int
    fileprivate init(steps: Int) { self.steps = steps }
    var floor: Int { steps / StepRules.stepsPerFloor }
    var remainingSteps: Int { StepRules.stepsPerFloor - steps % StepRules.stepsPerFloor }
    var fraction: Double { Double(steps % StepRules.stepsPerFloor) / Double(StepRules.stepsPerFloor) }
}
