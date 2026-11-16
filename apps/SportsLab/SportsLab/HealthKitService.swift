import Foundation
import HealthKit

struct HealthWorkoutSummary: Equatable, Identifiable {
    let id: UUID
    let activityName: String
    let startDate: Date
    let durationSeconds: TimeInterval
    let distanceMeters: Double?
    let averageHeartRateBPM: Double?
}

struct HealthMetricsSnapshot: Equatable {
    var authorized: Bool = false
    var statusMessage: String = "尚未连接 Apple 健康"
    var updatedAt: Date? = nil
    var restingHeartRateBPM: Double? = nil
    var latestHeartRateBPM: Double? = nil
    var vo2Max: Double? = nil
    var recentRunPaceSecondsPerKm: Double? = nil
    var recentRunDistanceKm: Double? = nil
    var golfWorkouts: [HealthWorkoutSummary] = []
    var tennisWorkouts: [HealthWorkoutSummary] = []
    var climbingWorkouts: [HealthWorkoutSummary] = []
    var runningWorkouts: [HealthWorkoutSummary] = []
}

@MainActor
final class HealthKitService: ObservableObject {
    @Published private(set) var snapshot = HealthMetricsSnapshot()
    @Published private(set) var loading = false

    private let store: HKHealthStore?

    init() {
        self.store = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
        if self.store == nil {
            snapshot.statusMessage = "当前设备不支持 Apple 健康，将使用本地输入与默认体能参数"
        }
    }

    var isAvailable: Bool { store != nil }

    private static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        let quantityIDs: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .restingHeartRate,
            .vo2Max,
            .distanceWalkingRunning,
            .runningSpeed,
            .underwaterDepth
        ]
        for id in quantityIDs {
            if let t = HKObjectType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        return types
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        guard let store else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            snapshot = try await fetchSnapshot(store: store)
        } catch {
            snapshot.authorized = false
            snapshot.statusMessage = "读取 Apple 健康失败：\(error.localizedDescription)"
        }
    }

    private func fetchSnapshot(store: HKHealthStore) async throws -> HealthMetricsSnapshot {
        async let resting = latestQuantity(store: store, identifier: .restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let latestHR = latestQuantity(store: store, identifier: .heartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let vo2 = latestQuantity(store: store, identifier: .vo2Max, unit: HKUnit(from: "ml/kg*min"))
        async let workouts = recentWorkouts(store: store, limit: 40)

        let (rhr, hr, vo2Value, workoutList) = try await (resting, latestHR, vo2, workouts)

        let runs = workoutList.filter { $0.workoutActivityType == .running }
        let latestRun = runs.first
        let runDistanceKm = latestRun?.totalDistance?.doubleValue(for: HKUnit.meterUnit(with: .kilo))
        let runPace: Double? = {
            guard let dist = runDistanceKm, dist > 0.1, let dur = latestRun?.duration, dur > 0 else { return nil }
            return dur / dist
        }()

        return HealthMetricsSnapshot(
            authorized: true,
            statusMessage: "已同步 Apple 健康最近体能与训练数据",
            updatedAt: Date(),
            restingHeartRateBPM: rhr,
            latestHeartRateBPM: hr,
            vo2Max: vo2Value,
            recentRunPaceSecondsPerKm: runPace,
            recentRunDistanceKm: runDistanceKm,
            golfWorkouts: workoutList.filter { $0.workoutActivityType == .golf }.map(Self.summarize),
            tennisWorkouts: workoutList.filter { $0.workoutActivityType == .tennis }.map(Self.summarize),
            climbingWorkouts: workoutList.filter { $0.workoutActivityType == .climbing }.map(Self.summarize),
            runningWorkouts: runs.map(Self.summarize)
        )
    }

    private static func summarize(_ workout: HKWorkout) -> HealthWorkoutSummary {
        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)
        let avgHR = hrType.flatMap { workout.statistics(for: $0)?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }
        let name: String
        switch workout.workoutActivityType {
        case .golf: name = "高尔夫"
        case .tennis: name = "网球"
        case .climbing: name = "攀岩"
        case .running: name = "跑步"
        default: name = "综合训练"
        }
        return HealthWorkoutSummary(
            id: workout.uuid,
            activityName: name,
            startDate: workout.startDate,
            durationSeconds: workout.duration,
            distanceMeters: workout.totalDistance?.doubleValue(for: HKUnit.meter()),
            averageHeartRateBPM: avgHR
        )
    }

    private func latestQuantity(store: HKHealthStore, identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func recentWorkouts(store: HKHealthStore, limit: Int) async throws -> [HKWorkout] {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: nil, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }
}
