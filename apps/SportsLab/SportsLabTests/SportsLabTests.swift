import XCTest
@testable import SportsLab

@MainActor
final class SportsLabTests: XCTestCase {
    func testGolfSwingAnalysis() {
        let onPlane = GolfSwingAnalyzer.analyze(
            club: "7号铁", backswingMs: 900, downswingMs: 300,
            peakAngularVelocityDegPerSec: 900, planeDeviationDegrees: 1.0
        )
        XCTAssertEqual(onPlane.tempoRatio, 3.0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(onPlane.consistencyScore, 90)
        XCTAssertFalse(onPlane.points.isEmpty)
    }

    func testGolfSwingPhaseDetectionFromMotionSamples() {
        // Synthetic 100Hz-like swing: 0.0s start -> 0.9s top pause -> 1.2s impact peak -> follow-through
        let samples: [MotionSample] = [
            MotionSample(timestamp: 0.00, gyroDegPerSec: 15, pitchDeg: -40, rollDeg: 0),
            MotionSample(timestamp: 0.10, gyroDegPerSec: 120, pitchDeg: -25, rollDeg: 10),
            MotionSample(timestamp: 0.30, gyroDegPerSec: 260, pitchDeg: 0, rollDeg: 22),
            MotionSample(timestamp: 0.60, gyroDegPerSec: 210, pitchDeg: 28, rollDeg: 35),
            MotionSample(timestamp: 0.85, gyroDegPerSec: 90, pitchDeg: 42, rollDeg: 44),
            MotionSample(timestamp: 1.00, gyroDegPerSec: 12, pitchDeg: 46, rollDeg: 46), // top of backswing
            MotionSample(timestamp: 1.10, gyroDegPerSec: 450, pitchDeg: 20, rollDeg: 30),
            MotionSample(timestamp: 1.20, gyroDegPerSec: 860, pitchDeg: -10, rollDeg: 14),
            MotionSample(timestamp: 1.30, gyroDegPerSec: 1120, pitchDeg: -38, rollDeg: 2), // impact peak
            MotionSample(timestamp: 1.40, gyroDegPerSec: 640, pitchDeg: -15, rollDeg: -18),
            MotionSample(timestamp: 1.50, gyroDegPerSec: 280, pitchDeg: 18, rollDeg: -32),
            MotionSample(timestamp: 1.60, gyroDegPerSec: 90, pitchDeg: 35, rollDeg: -40)
        ]

        let detected = GolfSwingAnalyzer.detectSwingPhases(samples: samples)
        XCTAssertNotNil(detected)
        XCTAssertEqual(Double(detected?.backswingMs ?? 0), 900, accuracy: 20)
        XCTAssertEqual(Double(detected?.downswingMs ?? 0), 300, accuracy: 20)
        XCTAssertEqual(detected?.peakGyro ?? 0, 1120, accuracy: 0.1)
        XCTAssertTrue(detected?.points.contains(where: { $0.phase == "backswing" }) ?? false)
        XCTAssertTrue(detected?.points.contains(where: { $0.phase == "downswing" }) ?? false)
    }

    func testGolfCoachingAdviceAndClubSummary() {
        let idealTip = GolfSwingAnalyzer.coachingAdvice(tempoRatio: 3.0, planeDeviationDegrees: 1.5)
        XCTAssertTrue(idealTip.contains("3:1"))

        let faultTip = GolfSwingAnalyzer.coachingAdvice(tempoRatio: 1.9, planeDeviationDegrees: 7.5)
        XCTAssertTrue(faultTip.contains("Over-the-Top"))

        let analyzer = GolfSwingAnalyzer()
        analyzer.records = [
            GolfSwingAnalyzer.analyze(club: "7号铁", backswingMs: 900, downswingMs: 300, peakAngularVelocityDegPerSec: 1000, planeDeviationDegrees: 1.0),
            GolfSwingAnalyzer.analyze(club: "7号铁", backswingMs: 960, downswingMs: 320, peakAngularVelocityDegPerSec: 1100, planeDeviationDegrees: 2.0)
        ]
        let summary = analyzer.clubSummary(for: "7号铁")
        XCTAssertEqual(summary?.count, 2)
        XCTAssertEqual(summary?.avgTempo ?? 0, 3.0, accuracy: 0.01)
    }

    func testTennisShotClassificationAndSummary() {
        let suite = UserDefaults(suiteName: "SportsLabTests.Tennis.\(UUID().uuidString)")!
        let tracker = TennisShotTracker(defaults: suite)
        tracker.addShot(kind: .firstServe, x: 0.65, y: 0.70)
        tracker.addShot(kind: .forehand, x: 0.35, y: 0.18)
        tracker.addShot(kind: .backhand, x: 0.05, y: 0.50)
        XCTAssertEqual(tracker.summary.totalShots, 3)
        XCTAssertEqual(tracker.summary.firstServeInRate, 1.0, accuracy: 0.01)
        XCTAssertEqual(tracker.summary.unforcedErrorCount, 1)
    }

    func testClimbingCheckInSummary() {
        let suite = UserDefaults(suiteName: "SportsLabTests.Climbing.\(UUID().uuidString)")!
        let store = ClimbingLogStore(defaults: suite)
        store.checkIn(gymOrCrag: "香蕉攀岩", routeName: "蓝线 #3", style: .bouldering, grade: "V4", outcome: .flash, notes: "")
        store.checkIn(gymOrCrag: "香蕉攀岩", routeName: "黑线 #1", style: .bouldering, grade: "V6", outcome: .attempt, notes: "")
        XCTAssertEqual(store.summary.completedCount, 1)
        XCTAssertEqual(store.summary.highestBouldering, "V4")

        if let project = store.entries.first(where: { !$0.outcome.isCompleted }) {
            store.markRedpoint(project.id)
        }
        XCTAssertEqual(store.summary.completedCount, 2)
        XCTAssertEqual(store.summary.highestBouldering, "V6")
    }

    func testMarathonPlanWithHealth() {
        let health = HealthMetricsSnapshot(authorized: true, statusMessage: "ok", vo2Max: 52.0, recentRunPaceSecondsPerKm: 300)
        let plan = MarathonPacingEngine.buildPlan(distance: .full, targetMinutes: 225, strategy: .negativeSplit, bodyWeightKg: 68, temperatureCelsius: 24, health: health)
        XCTAssertEqual(plan.splits.count, 9)
        XCTAssertGreaterThan(plan.splits.first!.paceSecondsPerKm, plan.splits.last!.paceSecondsPerKm)
        XCTAssertFalse(plan.fuelingCues.isEmpty)
    }

    func testMarathonRiegelKarvonenElevationAndPackingTotals() {
        // 10km in 45 min -> full marathon Riegel prediction (~3h 26m = ~12,380s)
        let predictedFull = MarathonPacingEngine.riegelPredictSeconds(
            knownDistanceKm: 10.0,
            knownDurationSeconds: 45 * 60,
            targetDistance: .full
        )
        XCTAssertGreaterThan(predictedFull, 11500)
        XCTAssertLessThan(predictedFull, 13200)

        let hrRange = MarathonPacingEngine.karvonenHeartRateRange(
            restingHR: 52,
            age: 30,
            intensityLow: 0.72,
            intensityHigh: 0.84
        )
        XCTAssertNotNil(hrRange)
        XCTAssertGreaterThanOrEqual(hrRange?.lowerBound ?? 0, 140)
        XCTAssertLessThanOrEqual(hrRange?.upperBound ?? 999, 175)

        let health = HealthMetricsSnapshot(
            authorized: true,
            statusMessage: "ok",
            restingHeartRateBPM: 52,
            vo2Max: 50,
            recentRunPaceSecondsPerKm: 310
        )
        let plan = MarathonPacingEngine.buildPlan(
            distance: .full,
            targetMinutes: 230,
            strategy: .conservativeStart,
            bodyWeightKg: 70,
            temperatureCelsius: 26,
            elevationGainMeters: 420,
            runnerAge: 30,
            health: health
        )
        XCTAssertGreaterThan(plan.elevationPenaltySecondsPerKm, 1.0)
        XCTAssertGreaterThan(plan.totalGelsCount, 4)
        XCTAssertGreaterThan(plan.totalSodiumMg, 1500)
        XCTAssertNotNil(plan.splits.first?.targetHRRange)
    }

    func testMarathonLiveRaceStateAndFuelingCountdown() {
        let health = HealthMetricsSnapshot(authorized: true, statusMessage: "ok", restingHeartRateBPM: 54, vo2Max: 52, recentRunPaceSecondsPerKm: 300)
        let plan = MarathonPacingEngine.buildPlan(
            distance: .full,
            targetMinutes: 240,
            strategy: .even,
            bodyWeightKg: 68,
            temperatureCelsius: 20,
            health: health
        )

        // At 25 minutes (1500s), next cue should be minuteMark == 30 (countdown == 300s)
        let early = MarathonPacingEngine.liveState(elapsedSeconds: 25 * 60, plan: plan)
        XCTAssertEqual(early.nextFuelingCue?.minuteMark, 30)
        XCTAssertEqual(early.secondsToNextCue ?? 0, 300, accuracy: 0.1)
        XCTAssertGreaterThan(early.estimatedDistanceKm, 4.0)
        XCTAssertLessThan(early.estimatedDistanceKm, 6.0)
        XCTAssertEqual(early.progressRatio, 25.0 / 240.0, accuracy: 0.01)
    }

    func testSavedMarathonPlanPersistence() {
        let suite = UserDefaults(suiteName: "SportsLabTests.MarathonPlans.\(UUID().uuidString)")!
        let store = MarathonPlanStore(defaults: suite)
        store.savePlan(
            raceName: "上海全马破330",
            distance: .full,
            strategy: .negativeSplit,
            targetMinutes: 210,
            elevationGainMeters: 160,
            bodyWeightKg: 68,
            temperatureCelsius: 20,
            runnerAge: 32
        )
        XCTAssertEqual(store.savedPlans.count, 1)
        XCTAssertEqual(store.savedPlans.first?.raceName, "上海全马破330")

        let reloaded = MarathonPlanStore(defaults: suite)
        XCTAssertEqual(reloaded.savedPlans.count, 1)
        XCTAssertEqual(reloaded.savedPlans.first?.targetMinutes, 210)

        reloaded.delete(reloaded.savedPlans[0].id)
        XCTAssertTrue(reloaded.savedPlans.isEmpty)
    }
}
