import CoreMotion
import Foundation

struct SwingPoint: Codable, Equatable {
    let x: Double
    let y: Double
    let phase: String
}

struct MotionSample: Equatable {
    let timestamp: TimeInterval
    let gyroDegPerSec: Double
    let pitchDeg: Double
    let rollDeg: Double
}

struct GolfSwingRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let club: String
    let backswingMs: Int
    let downswingMs: Int
    let peakAngularVelocityDegPerSec: Double
    let planeDeviationDegrees: Double
    let estimatedClubSpeedMph: Double
    let tempoRatio: Double
    let consistencyScore: Int
    let pathTendency: String
    let points: [SwingPoint]
}

@MainActor
final class GolfSwingAnalyzer: ObservableObject {
    @Published var records: [GolfSwingRecord] = []
    @Published var isCapturing = false
    @Published var liveStatusText = "待机中（支持真机陀螺仪实时采集或手动模拟）"
    @Published var liveSamplesCount = 0

    private let motionManager = CMMotionManager()
    private let storageKey = "sportslab.golf.records.v1"
    private var capturedSamples: [MotionSample] = []

    init() {
        load()
    }

    static func analyze(
        club: String,
        backswingMs: Int,
        downswingMs: Int,
        peakAngularVelocityDegPerSec: Double,
        planeDeviationDegrees: Double,
        points: [SwingPoint]? = nil,
        date: Date = Date()
    ) -> GolfSwingRecord {
        let clampedBack = max(250, min(backswingMs, 2400))
        let clampedDown = max(120, min(downswingMs, 900))
        let tempoRatio = Double(clampedBack) / Double(clampedDown)

        // Ideal tempo is ~3.0:1; penalize deviation and excessive plane tilt.
        let tempoPenalty = min(45.0, abs(tempoRatio - 3.0) * 18.0)
        let planePenalty = min(45.0, abs(planeDeviationDegrees) * 3.0)
        let consistency = max(10, min(100, Int((100.0 - tempoPenalty - planePenalty).rounded())))

        let clubMultiplier: Double
        switch club {
        case "1号木": clubMultiplier = 0.088
        case "3号木": clubMultiplier = 0.082
        case "7号铁": clubMultiplier = 0.072
        default: clubMultiplier = 0.065
        }
        let estimatedSpeed = max(35.0, min(135.0, peakAngularVelocityDegPerSec * clubMultiplier))

        let tendency: String
        if planeDeviationDegrees > 4.0 {
            tendency = "偏外下杆 (Over-the-Top / 右曲倾向)"
        } else if planeDeviationDegrees < -4.0 {
            tendency = "偏内下杆 (In-to-Out / 左曲倾向)"
        } else {
            tendency = "杆面方正 (On-Plane)"
        }

        let resolvedPoints = points ?? generateTrajectory(planeDeviationDegrees: planeDeviationDegrees)

        return GolfSwingRecord(
            id: UUID(),
            date: date,
            club: club,
            backswingMs: clampedBack,
            downswingMs: clampedDown,
            peakAngularVelocityDegPerSec: peakAngularVelocityDegPerSec,
            planeDeviationDegrees: planeDeviationDegrees,
            estimatedClubSpeedMph: (estimatedSpeed * 10).rounded() / 10,
            tempoRatio: (tempoRatio * 100).rounded() / 100,
            consistencyScore: consistency,
            pathTendency: tendency,
            points: resolvedPoints
        )
    }

    static func generateTrajectory(planeDeviationDegrees: Double) -> [SwingPoint] {
        var pts: [SwingPoint] = []
        let dev = max(-15.0, min(15.0, planeDeviationDegrees)) / 45.0

        // Backswing arc: bottom -> top-right
        for i in 0...16 {
            let t = Double(i) / 16.0
            let x = 0.50 + sin(t * .pi * 0.65) * 0.34
            let y = 0.85 - pow(t, 0.85) * 0.68
            pts.append(SwingPoint(x: x, y: y, phase: "backswing"))
        }

        // Downswing arc: top-right -> impact -> follow-through
        for i in 1...18 {
            let t = Double(i) / 18.0
            let baseX = 0.50 + cos(t * .pi * 0.95) * 0.34 - t * 0.42
            let x = max(0.08, min(0.92, baseX + sin(t * .pi) * dev * 0.28))
            let y = 0.17 + sin(t * .pi * 0.72) * 0.68
            pts.append(SwingPoint(x: x, y: y, phase: "downswing"))
        }
        return pts
    }

    static func detectSwingPhases(
        samples: [MotionSample]
    ) -> (backswingMs: Int, downswingMs: Int, peakGyro: Double, planeDeviation: Double, points: [SwingPoint])? {
        guard samples.count >= 12 else { return nil }

        // Locate peak downswing angular velocity (impact zone).
        guard let impactIndex = samples.indices.max(by: {
            abs(samples[$0].gyroDegPerSec) < abs(samples[$1].gyroDegPerSec)
        }) else {
            return nil
        }

        let peakGyro = abs(samples[impactIndex].gyroDegPerSec)
        guard peakGyro >= 120.0, impactIndex >= 4 else { return nil }

        // Find top of backswing: minimum angular velocity magnitude before impact (transition pause).
        let transitionSearchStart = max(1, impactIndex / 4)
        let transitionSearchEnd = max(transitionSearchStart, impactIndex - 1)
        let topIndex = (transitionSearchStart...transitionSearchEnd).min(by: {
            abs(samples[$0].gyroDegPerSec) < abs(samples[$1].gyroDegPerSec)
        }) ?? max(1, impactIndex - 2)

        // Find backswing start: first sample exceeding 35 deg/s before top.
        let backswingThreshold = 35.0
        let startIndex = (0..<topIndex).first(where: {
            abs(samples[$0].gyroDegPerSec) >= backswingThreshold
        }) ?? 0

        let backswingDuration = max(0.25, samples[topIndex].timestamp - samples[startIndex].timestamp)
        let downswingDuration = max(0.12, samples[impactIndex].timestamp - samples[topIndex].timestamp)

        let backswingMs = Int((backswingDuration * 1000.0).rounded())
        let downswingMs = Int((downswingDuration * 1000.0).rounded())

        // Estimate plane deviation from roll change between backswing and downswing.
        let backswingRolls = samples[startIndex...topIndex].map(\.rollDeg)
        let downswingRolls = samples[topIndex...impactIndex].map(\.rollDeg)
        let avgBackRoll = backswingRolls.reduce(0, +) / Double(max(1, backswingRolls.count))
        let avgDownRoll = downswingRolls.reduce(0, +) / Double(max(1, downswingRolls.count))
        let planeDeviation = max(-15.0, min(15.0, (avgDownRoll - avgBackRoll) * 0.45))

        // Build normalized trajectory points from captured pitch & roll angles.
        let followEnd = min(samples.count - 1, impactIndex + max(2, (impactIndex - topIndex) / 2))
        let swingSlice = Array(samples[startIndex...followEnd])
        let pitches = swingSlice.map(\.pitchDeg)
        let rolls = swingSlice.map(\.rollDeg)
        let minPitch = pitches.min() ?? -45.0
        let maxPitch = max(minPitch + 1.0, pitches.max() ?? 45.0)
        let minRoll = rolls.min() ?? -45.0
        let maxRoll = max(minRoll + 1.0, rolls.max() ?? 45.0)

        let topOffset = max(1, topIndex - startIndex)
        let points: [SwingPoint] = swingSlice.enumerated().map { idx, sample in
            let normX = 0.14 + ((sample.rollDeg - minRoll) / (maxRoll - minRoll)) * 0.72
            let normY = 0.85 - ((sample.pitchDeg - minPitch) / (maxPitch - minPitch)) * 0.68
            let phase = idx <= topOffset ? "backswing" : "downswing"
            return SwingPoint(
                x: max(0.08, min(0.92, normX)),
                y: max(0.12, min(0.88, normY)),
                phase: phase
            )
        }

        return (
            backswingMs: backswingMs,
            downswingMs: downswingMs,
            peakGyro: peakGyro,
            planeDeviation: (planeDeviation * 10).rounded() / 10,
            points: points
        )
    }

    static func coachingAdvice(tempoRatio: Double, planeDeviationDegrees: Double) -> String {
        var tips: [String] = []
        if tempoRatio < 2.4 {
            tips.append("上杆过快或过渡急促，建议在顶点略作停顿，建立 3:1 节奏。")
        } else if tempoRatio > 3.6 {
            tips.append("上杆偏慢拖沓，可略微加快上杆启动保持连贯。")
        } else {
            tips.append("挥杆节奏接近巡回赛 3:1 黄金比例。")
        }

        if planeDeviationDegrees > 4.0 {
            tips.append("下杆偏外切 (Over-the-Top)，可尝试先转动下半身并让右手肘贴近身体。")
        } else if planeDeviationDegrees < -4.0 {
            tips.append("下杆偏内侧过多，注意收杆时胸口同步转向目标防止左曲。")
        } else {
            tips.append("挥杆平面稳定，继续保持当前起杆与下杆轨迹。")
        }
        return tips.joined(separator: " ")
    }

    func clubSummary(for club: String) -> (count: Int, avgSpeedMph: Double, avgTempo: Double, avgScore: Int)? {
        let filtered = records.filter { $0.club == club }
        guard !filtered.isEmpty else { return nil }
        let count = filtered.count
        let avgSpeed = filtered.map(\.estimatedClubSpeedMph).reduce(0, +) / Double(count)
        let avgTempo = filtered.map(\.tempoRatio).reduce(0, +) / Double(count)
        let avgScore = Int((Double(filtered.map(\.consistencyScore).reduce(0, +)) / Double(count)).rounded())
        return (
            count: count,
            avgSpeedMph: (avgSpeed * 10).rounded() / 10,
            avgTempo: (avgTempo * 100).rounded() / 100,
            avgScore: avgScore
        )
    }

    func recordManual(
        club: String,
        backswingMs: Int,
        downswingMs: Int,
        peakAngularVelocityDegPerSec: Double,
        planeDeviationDegrees: Double
    ) {
        let item = Self.analyze(
            club: club,
            backswingMs: backswingMs,
            downswingMs: downswingMs,
            peakAngularVelocityDegPerSec: peakAngularVelocityDegPerSec,
            planeDeviationDegrees: planeDeviationDegrees
        )
        records.insert(item, at: 0)
        save()
    }

    func startLiveCapture(club: String) {
        guard motionManager.isDeviceMotionAvailable else {
            liveStatusText = "当前设备不支持 CoreMotion（例如模拟器），请使用下方手动参数模拟挥杆"
            return
        }
        capturedSamples = []
        liveSamplesCount = 0
        isCapturing = true
        liveStatusText = "正在采集 \(club) 挥杆角速度与姿态数据 (100Hz)..."

        motionManager.deviceMotionUpdateInterval = 0.01
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let rate = motion.rotationRate
            let totalDeg = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z) * 180.0 / .pi
            let pitchDeg = motion.attitude.pitch * 180.0 / .pi
            let rollDeg = motion.attitude.roll * 180.0 / .pi
            let sample = MotionSample(
                timestamp: motion.timestamp,
                gyroDegPerSec: totalDeg,
                pitchDeg: pitchDeg,
                rollDeg: rollDeg
            )
            self.capturedSamples.append(sample)
            self.liveSamplesCount = self.capturedSamples.count
        }
    }

    func stopLiveCapture(club: String = "7号铁") {
        motionManager.stopDeviceMotionUpdates()
        isCapturing = false

        if let detected = Self.detectSwingPhases(samples: capturedSamples) {
            let record = Self.analyze(
                club: club,
                backswingMs: detected.backswingMs,
                downswingMs: detected.downswingMs,
                peakAngularVelocityDegPerSec: detected.peakGyro,
                planeDeviationDegrees: detected.planeDeviation,
                points: detected.points
            )
            records.insert(record, at: 0)
            save()
            liveStatusText = "采集完成：共 \(capturedSamples.count) 帧，已识别上杆/下杆分段"
        } else {
            liveStatusText = "已停止采集（有效挥杆峰值不足或样本过少，未生成记录）"
        }
        capturedSamples = []
    }

    func deleteRecord(_ record: GolfSwingRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([GolfSwingRecord].self, from: data) else {
            return
        }
        records = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
