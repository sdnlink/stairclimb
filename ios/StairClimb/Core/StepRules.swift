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

    static func sensorProgress(total: Double) throws -> StepProgress {
        guard total.isFinite, total >= 0, total <= Double(maximumSteps) else {
            throw ValidationError.outOfRange
        }
        // Sensor quantities are Double. Publish whole cumulative steps, never round up.
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

// Pure, bounded presentation rules. The authoritative step snapshot is immutable.
enum StaircaseRules {
    static let maximumFloor = StepRules.maximumSteps / StepRules.stepsPerFloor
    static func centeredBase(_ floor: Int) -> Int { max(0, min(maximumFloor - 4, floor - 2)) }
    static func maximumBase(near floor: Int) -> Int { max(0, min(maximumFloor - 4, floor + 1)) }
    static func browse(base: Int, delta: Int, near floor: Int) -> Int {
        // UI sends small deltas; clamp before adding to avoid overflowing foreign input.
        max(0, min(maximumBase(near: floor), base + max(-5, min(5, delta))))
    }
    static func route(from old: Int?, to target: Int, replay: Bool, animated: Bool) -> [Int] {
        let end = max(0, min(maximumFloor, target))
        guard animated else { return [end] }
        guard let old else { return [end] } // First read/day change never replays yesterday.
        let start = max(0, min(maximumFloor, old))
        if replay { return Array(max(0, end - 4)...end) }
        guard end > start else { return [end] }
        return Array(max(start, end - 8)...end)
    }
}
