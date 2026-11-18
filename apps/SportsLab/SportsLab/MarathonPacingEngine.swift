import Foundation

enum MarathonDistance: String, CaseIterable, Identifiable {
    case half = "半程马拉松 (21.1 km)"
    case full = "全程马拉松 (42.2 km)"
    var id: String { rawValue }
    var kilometers: Double { self == .half ? 21.0975 : 42.195 }
}

enum PacingStrategyMode: String, CaseIterable, Identifiable {
    case even = "匀速巡航 (Even Split)"
    case negativeSplit = "后程加速 (Negative Split)"
    case conservativeStart = "稳健起步防掉速"
    var id: String { rawValue }
}

struct MarathonSplit: Equatable, Identifiable {
    let segmentLabel: String
    let distanceKm: Double
    let paceSecondsPerKm: Double
    let cumulativeSeconds: Double
    let targetHRRange: ClosedRange<Int>?
    let zoneLabel: String
    var id: String { segmentLabel }
}

struct FuelingCue: Equatable, Identifiable {
    let minuteMark: Int
    let distanceKm: Double
    let action: String
    let carbsGrams: Int
    let waterMl: Int
    let sodiumMg: Int
    var id: Int { minuteMark }
}

struct MarathonPlan: Equatable {
    let targetTotalSeconds: Double
    let averagePaceSecondsPerKm: Double
    let elevationPenaltySecondsPerKm: Double
    let carbsPerHourGrams: Int
    let waterPerHourMl: Int
    let sodiumPerHourMg: Int
    let totalGelsCount: Int
    let totalWaterMl: Int
    let totalSodiumMg: Int
    let splits: [MarathonSplit]
    let fuelingCues: [FuelingCue]
    let healthBasisNote: String
}

struct LiveRaceState: Equatable {
    let elapsedSeconds: Double
    let estimatedDistanceKm: Double
    let progressRatio: Double
    let currentSplit: MarathonSplit?
    let nextFuelingCue: FuelingCue?
    let secondsToNextCue: Double?
}

enum MarathonPacingEngine {
    /// Riegel race-time prediction: T2 = T1 * (D2 / D1)^1.06
    static func riegelPredictSeconds(
        knownDistanceKm: Double,
        knownDurationSeconds: Double,
        targetDistance: MarathonDistance
    ) -> Double {
        guard knownDistanceKm > 0.5, knownDurationSeconds > 60 else {
            return targetDistance == .half ? 120 * 60 : 250 * 60
        }
        return knownDurationSeconds * pow(targetDistance.kilometers / knownDistanceKm, 1.06)
    }

    static func estimateTargetSeconds(distance: MarathonDistance, health: HealthMetricsSnapshot) -> Double {
        if let longestRun = health.runningWorkouts
            .filter({ ($0.distanceMeters ?? 0) >= 5000 })
            .max(by: { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }),
           let meters = longestRun.distanceMeters, meters >= 5000 {
            return riegelPredictSeconds(
                knownDistanceKm: meters / 1000.0,
                knownDurationSeconds: longestRun.durationSeconds,
                targetDistance: distance
            )
        }
        if let recentPace = health.recentRunPaceSecondsPerKm, recentPace > 150, recentPace < 600 {
            let marathonFactor = distance == .full ? 1.07 : 1.03
            return recentPace * marathonFactor * distance.kilometers
        }
        if let vo2 = health.vo2Max, vo2 > 25 {
            let basePace = max(210.0, min(450.0, 540.0 - (vo2 - 30.0) * 5.0))
            return basePace * distance.kilometers
        }
        return distance == .half ? 120 * 60 : 250 * 60
    }

    static func karvonenHeartRateRange(
        restingHR: Double?,
        age: Int,
        intensityLow: Double,
        intensityHigh: Double
    ) -> ClosedRange<Int>? {
        guard let rhr = restingHR, rhr >= 35, rhr <= 110 else { return nil }
        let safeAge = max(16, min(80, age))
        let maxHR = 208.0 - 0.7 * Double(safeAge)
        let reserve = max(40.0, maxHR - rhr)
        let low = Int((rhr + reserve * intensityLow).rounded())
        let high = Int((rhr + reserve * intensityHigh).rounded())
        return min(low, high)...max(low, high)
    }

    static func buildPlan(
        distance: MarathonDistance,
        targetMinutes: Int,
        strategy: PacingStrategyMode,
        bodyWeightKg: Double,
        temperatureCelsius: Double,
        elevationGainMeters: Double = 0,
        runnerAge: Int = 32,
        health: HealthMetricsSnapshot
    ) -> MarathonPlan {
        let totalSeconds = Double(max(60, min(480, targetMinutes)) * 60)
        let totalKm = distance.kilometers
        let avgPace = totalSeconds / totalKm
        let elevPerKm = max(0.0, elevationGainMeters) / totalKm
        // ~0.12s/km pace cost per 1m/km average climb
        let elevPenalty = elevPerKm * 0.12

        var splits: [MarathonSplit] = []
        var covered = 0.0
        var elapsed = 0.0

        while covered < totalKm - 0.01 {
            let nextKm = min(totalKm, covered + 5.0)
            let segLen = nextKm - covered
            let progress = (covered + segLen * 0.5) / totalKm
            let multiplier: Double
            let hrLow: Double
            let hrHigh: Double
            let zoneLabel: String

            switch strategy {
            case .even:
                multiplier = 1.0
                hrLow = 0.76 + progress * 0.06
                hrHigh = 0.82 + progress * 0.06
                zoneLabel = progress < 0.7 ? "有氧巡航 Z3" : "乳酸阈维持 Z4"
            case .negativeSplit:
                multiplier = 1.025 - progress * 0.05
                hrLow = 0.72 + progress * 0.12
                hrHigh = 0.78 + progress * 0.11
                zoneLabel = progress < 0.45 ? "蓄力有氧 Z2-Z3" : (progress < 0.8 ? "稳步提速 Z3" : "后程冲刺 Z4")
            case .conservativeStart:
                multiplier = progress < 0.25 ? 1.035 : (progress < 0.75 ? 0.995 : 0.985)
                hrLow = 0.70 + progress * 0.12
                hrHigh = 0.76 + progress * 0.11
                zoneLabel = progress < 0.25 ? "起步控心率 Z2" : "中后程巡航 Z3-Z4"
            }

            let segPace = avgPace * multiplier + elevPenalty * 0.25
            elapsed += segPace * segLen
            let hrRange = karvonenHeartRateRange(
                restingHR: health.restingHeartRateBPM,
                age: runnerAge,
                intensityLow: hrLow,
                intensityHigh: hrHigh
            )
            let label = nextKm < totalKm
                ? "\(Int(covered))–\(Int(nextKm)) km"
                : "\(Int(covered))–\(String(format: "%.1f", totalKm)) km"
            splits.append(MarathonSplit(
                segmentLabel: label,
                distanceKm: nextKm,
                paceSecondsPerKm: segPace,
                cumulativeSeconds: elapsed,
                targetHRRange: hrRange,
                zoneLabel: zoneLabel
            ))
            covered = nextKm
        }

        let durationHours = totalSeconds / 3600.0
        let carbsPerHour = distance == .full && durationHours >= 3.0 ? 75 : 60
        let tempExtra = max(0.0, (temperatureCelsius - 16.0) * 28.0)
        let waterPerHour = Int(min(950.0, max(350.0, bodyWeightKg * 7.5 + tempExtra)).rounded())
        let sodiumPerHour = Int(min(900.0, max(350.0, 420.0 + max(0.0, temperatureCelsius - 18.0) * 22.0)).rounded())

        var cues: [FuelingCue] = []
        var minute = 30
        var totalWater = 0
        var totalSodium = 0
        var totalCarbs = 0
        while Double(minute * 60) < totalSeconds - 600 {
            let kmAtCue = (Double(minute * 60) / totalSeconds) * totalKm
            let gelGrams = carbsPerHour / 2
            let waterMl = waterPerHour / 2
            let sodiumMg = sodiumPerHour / 2
            let isCaffeine = distance == .full && (minute == 150 || minute == 210)
            let action: String
            if isCaffeine {
                action = "含咖啡因能量胶 + 电解质水（后程抗疲劳）"
            } else if minute % 60 == 0 {
                action = "能量胶 + 盐丸/电解质水补给"
            } else {
                action = "能量胶 + 饮水站少量多次补水"
            }
            cues.append(FuelingCue(
                minuteMark: minute,
                distanceKm: kmAtCue,
                action: action,
                carbsGrams: gelGrams,
                waterMl: waterMl,
                sodiumMg: sodiumMg
            ))
            totalCarbs += gelGrams
            totalWater += waterMl
            totalSodium += sodiumMg
            minute += 30
        }

        // Standard gel ~25g carbs
        let gelsCount = max(1, Int(ceil(Double(totalCarbs) / 25.0)))

        let basis: String
        if let pace = health.recentRunPaceSecondsPerKm {
            basis = "已结合 Apple 健康跑步配速（\(formatPace(pace))/km）" + (health.restingHeartRateBPM.map { "与静息心率 \(Int($0.rounded())) bpm 计算 Karvonen 区间" } ?? "")
        } else if let vo2 = health.vo2Max {
            basis = "已参考 Apple 健康 VO2Max \(String(format: "%.1f", vo2)) 测算目标配速"
        } else {
            basis = "使用目标完赛时间与体重/气温/爬升参数测算（同步 Apple 健康后自动校准心率区间）"
        }

        return MarathonPlan(
            targetTotalSeconds: totalSeconds,
            averagePaceSecondsPerKm: avgPace,
            elevationPenaltySecondsPerKm: elevPenalty,
            carbsPerHourGrams: carbsPerHour,
            waterPerHourMl: waterPerHour,
            sodiumPerHourMg: sodiumPerHour,
            totalGelsCount: gelsCount,
            totalWaterMl: totalWater,
            totalSodiumMg: totalSodium,
            splits: splits,
            fuelingCues: cues,
            healthBasisNote: basis
        )
    }

    static func liveState(elapsedSeconds: Double, plan: MarathonPlan) -> LiveRaceState {
        let elapsed = max(0.0, elapsedSeconds)
        let totalKm = plan.splits.last?.distanceKm ?? 0.0

        var prevTime = 0.0
        var prevKm = 0.0
        var activeSplit = plan.splits.last
        var estKm = totalKm

        for split in plan.splits {
            if elapsed <= split.cumulativeSeconds {
                activeSplit = split
                let segDuration = max(1.0, split.cumulativeSeconds - prevTime)
                let segFraction = (elapsed - prevTime) / segDuration
                estKm = prevKm + (split.distanceKm - prevKm) * segFraction
                break
            }
            prevTime = split.cumulativeSeconds
            prevKm = split.distanceKm
        }

        let nextCue = plan.fuelingCues.first { Double($0.minuteMark * 60) > elapsed }
        let countdown = nextCue.map { max(0.0, Double($0.minuteMark * 60) - elapsed) }
        let ratio = plan.targetTotalSeconds > 0 ? min(1.0, elapsed / plan.targetTotalSeconds) : 0.0

        return LiveRaceState(
            elapsedSeconds: elapsed,
            estimatedDistanceKm: max(0.0, min(totalKm, estKm)),
            progressRatio: ratio,
            currentSplit: activeSplit,
            nextFuelingCue: nextCue,
            secondsToNextCue: countdown
        )
    }

    static func formatPace(_ secondsPerKm: Double) -> String {
        let total = max(0, Int(secondsPerKm.rounded()))
        return String(format: "%d'%02d\"", total / 60, total % 60)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
