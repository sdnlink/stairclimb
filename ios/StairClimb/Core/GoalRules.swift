enum GoalRules {
    static let minimumTarget = 100

    enum ValidationError: Error, Equatable {
        case invalidTarget
        case invalidSteps
    }

    static func evaluate(target: Int, steps: Int?) throws -> GoalProgress {
        guard (minimumTarget...StepRules.maximumSteps).contains(target) else {
            throw ValidationError.invalidTarget
        }
        guard let steps else {
            return GoalProgress(target: target, steps: nil, fraction: nil,
                                remainingSteps: nil, isComplete: nil)
        }

        let validatedSteps: Int
        do {
            validatedSteps = try StepRules.progress(steps: steps).steps
        } catch {
            throw ValidationError.invalidSteps
        }

        return GoalProgress(target: target, steps: validatedSteps,
                            fraction: Double(min(validatedSteps, target)) / Double(target),
                            remainingSteps: max(0, target - validatedSteps),
                            isComplete: validatedSteps >= target)
    }
}

// Unknown readings stay unknown; a measured zero is a distinct, valid snapshot.
struct GoalProgress: Equatable {
    let target: Int
    let steps: Int?
    let fraction: Double?
    let remainingSteps: Int?
    let isComplete: Bool?

    fileprivate init(target: Int, steps: Int?, fraction: Double?,
                     remainingSteps: Int?, isComplete: Bool?) {
        self.target = target
        self.steps = steps
        self.fraction = fraction
        self.remainingSteps = remainingSteps
        self.isComplete = isComplete
    }
}
