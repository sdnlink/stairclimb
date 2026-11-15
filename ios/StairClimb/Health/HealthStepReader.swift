import Foundation
import HealthKit

enum HealthReading: Equatable {
    case total(Double)
    case noReadableData
}

@MainActor
protocol HealthStepReading {
    var isAvailable: Bool { get }
    func requestAccess() async throws
    func readSteps(in day: ShanghaiDay) async throws -> HealthReading
}

@MainActor
final class HealthStepReader: HealthStepReading {
    private let store = HKHealthStore()
    private let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    enum Failure: Error { case unavailable, requestFailed }

    func requestAccess() async throws {
        guard isAvailable else { throw Failure.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: [stepType]) { completed, error in
                if let error { continuation.resume(throwing: error) }
                else if completed { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: Failure.requestFailed) }
            }
        }
        // Completion says the request finished, not that read access was granted.
        // HealthKit deliberately cannot reveal a user's read refusal.
    }

    func readSteps(in day: ShanghaiDay) async throws -> HealthReading {
        guard isAvailable else { throw Failure.unavailable }
        let predicate = HKQuery.predicateForSamples(withStart: day.start, end: day.end,
            options: [.strictStartDate, .strictEndDate])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, statistics, error in
                if let error { continuation.resume(throwing: error); return }
                guard let quantity = statistics?.sumQuantity() else {
                    continuation.resume(returning: HealthReading.noReadableData)
                    return
                }
                continuation.resume(returning: HealthReading.total(quantity.doubleValue(for: .count())))
            }
            store.execute(query)
        }
    }
}
