import Foundation

struct CircleChannel: Decodable, Equatable {
    let id: String
    let date: String
    let minSteps: Int
    let maxSteps: Int
    let bandSteps: Int

    func validate(member: LeaderboardEntry, day: ShanghaiDay, userID: String) throws {
        let progress = try StepRules.progress(steps: member.steps)
        guard try Self.expected(day: day, steps: member.steps) == self,
              member.floor == progress.floor, member.remainingSteps == progress.remainingSteps,
              member.position >= 1, member.isMe == (member.id == userID) else { throw NetworkFailure.response }
    }

    static func expected(day: ShanghaiDay, steps: Int) throws -> CircleChannel {
        _ = try StepRules.progress(steps: steps)
        let lower = steps / StepRules.circleBandSteps * StepRules.circleBandSteps
        let upper = lower + StepRules.circleBandSteps - 1
        return CircleChannel(id: "\(day.date):\(lower)-\(upper)", date: day.date,
                             minSteps: lower, maxSteps: upper, bandSteps: StepRules.circleBandSteps)
    }
}
