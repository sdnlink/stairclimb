import SwiftUI

@MainActor
struct MarathonStrategyView: View {
    @ObservedObject var health: HealthKitService

    @State private var distance: MarathonDistance = .full
    @State private var strategy: PacingStrategyMode = .negativeSplit
    @State private var targetMinutes: Double = 240
    @State private var bodyWeightKg: Double = 65
    @State private var temperatureCelsius: Double = 18
    @State private var elevationGainMeters: Double = 120
    @State private var runnerAge: Int = 32
    @State private var initializedFromHealth = false

    private var plan: MarathonPlan {
        MarathonPacingEngine.buildPlan(
            distance: distance,
            targetMinutes: Int(targetMinutes),
            strategy: strategy,
            bodyWeightKg: bodyWeightKg,
            temperatureCelsius: temperatureCelsius,
            elevationGainMeters: elevationGainMeters,
            runnerAge: runnerAge,
            health: health.snapshot
        )
    }

    var body: some View {
        List {
            Section("体能校准与比赛参数") {
                Text(plan.healthBasisNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("比赛项目", selection: $distance) {
                    ForEach(MarathonDistance.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: distance) { _, newValue in
                    let est = MarathonPacingEngine.estimateTargetSeconds(distance: newValue, health: health.snapshot)
                    targetMinutes = max(70, min(390, (est / 60.0).rounded()))
                }
                Picker("配速策略", selection: $strategy) {
                    ForEach(PacingStrategyMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper("跑者年龄（心率区间测算）: \(runnerAge) 岁", value: $runnerAge, in: 18...75)
                VStack(alignment: .leading) {
                    Text("目标完赛: \(MarathonPacingEngine.formatDuration(targetMinutes * 60))（均速 \(MarathonPacingEngine.formatPace(plan.averagePaceSecondsPerKm))/km）")
                    Slider(value: $targetMinutes, in: 70...390, step: 5)
                }
                VStack(alignment: .leading) {
                    Text("体重: \(Int(bodyWeightKg)) kg · 气温: \(Int(temperatureCelsius)) ℃")
                    Slider(value: $bodyWeightKg, in: 45...105, step: 1)
                    Slider(value: $temperatureCelsius, in: 5...32, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("赛道累计爬升: \(Int(elevationGainMeters)) m（等效修正 +\(String(format: "%.1f", plan.elevationPenaltySecondsPerKm))s/km）")
                    Slider(value: $elevationGainMeters, in: 0...800, step: 20)
                }
                Button("按 Apple 健康数据重置推荐时间") {
                    let est = MarathonPacingEngine.estimateTargetSeconds(distance: distance, health: health.snapshot)
                    targetMinutes = max(70, min(390, (est / 60.0).rounded()))
                }
            }

            if !health.snapshot.runningWorkouts.isEmpty {
                Section("近期跑步参考（点击用 Riegel 公式推算）") {
                    ForEach(health.snapshot.runningWorkouts.prefix(4)) { run in
                        let km = (run.distanceMeters ?? 0) / 1000.0
                        Button {
                            if km >= 3.0 {
                                let pred = MarathonPacingEngine.riegelPredictSeconds(
                                    knownDistanceKm: km,
                                    knownDurationSeconds: run.durationSeconds,
                                    targetDistance: distance
                                )
                                targetMinutes = max(70, min(390, (pred / 60.0).rounded()))
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(String(format: "%.1f", km)) km · \(MarathonPacingEngine.formatDuration(run.durationSeconds))")
                                        .font(.subheadline)
                                    Text(run.startDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if km > 0.2 {
                                    Text("\(MarathonPacingEngine.formatPace(run.durationSeconds / km))/km")
                                        .font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                }
            }

            Section("分段配速趋势") {
                SplitPaceChart(splits: plan.splits)
                    .frame(height: 120)
                    .padding(.vertical, 4)
                ForEach(plan.splits) { split in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(split.segmentLabel).font(.subheadline)
                            Text(split.zoneLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(MarathonPacingEngine.formatPace(split.paceSecondsPerKm))/km")
                                .monospacedDigit().font(.subheadline.bold())
                            if let hr = split.targetHRRange {
                                Text("\(hr.lowerBound)–\(hr.upperBound) bpm · \(MarathonPacingEngine.formatDuration(split.cumulativeSeconds))")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            } else {
                                Text(MarathonPacingEngine.formatDuration(split.cumulativeSeconds))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("赛前补给打包清单") {
                LabeledContent("能量胶建议携带", value: "约 \(plan.totalGelsCount) 支（每支约 25g 碳水）")
                LabeledContent("全程补水总量", value: "约 \(plan.totalWaterMl) ml（\(plan.waterPerHourMl) ml/h）")
                LabeledContent("全程钠/电解质", value: "约 \(plan.totalSodiumMg) mg（\(plan.sodiumPerHourMg) mg/h）")
            }

            Section("补给时间轴（每 30 分钟）") {
                ForEach(plan.fuelingCues) { cue in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(cue.minuteMark) 分钟 · 约 \(String(format: "%.1f", cue.distanceKm)) km")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(cue.carbsGrams)g 碳水 · \(cue.sodiumMg)mg 钠 · \(cue.waterMl)ml")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(cue.action).font(.caption)
                    }
                }
            }
        }
        .navigationTitle("马拉松配速与补给")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("同步健康") { Task { await health.refresh() } }.disabled(health.loading)
            }
        }
        .onAppear {
            guard !initializedFromHealth else { return }
            initializedFromHealth = true
            let est = MarathonPacingEngine.estimateTargetSeconds(distance: distance, health: health.snapshot)
            targetMinutes = max(70, min(390, (est / 60.0).rounded()))
        }
    }
}

private struct SplitPaceChart: View {
    let splits: [MarathonSplit]

    var body: some View {
        Canvas { context, size in
            guard !splits.isEmpty else { return }
            let paces = splits.map(\.paceSecondsPerKm)
            let minP = (paces.min() ?? 240) - 8
            let maxP = (paces.max() ?? 360) + 8
            let span = max(10.0, maxP - minP)
            let barW = (size.width - CGFloat(splits.count - 1) * 6) / CGFloat(splits.count)

            for (idx, split) in splits.enumerated() {
                // Faster pace (lower seconds) -> taller bar
                let norm = 1.0 - (split.paceSecondsPerKm - minP) / span
                let barH = max(16.0, CGFloat(norm) * (size.height - 20))
                let x = CGFloat(idx) * (barW + 6)
                let rect = CGRect(x: x, y: size.height - barH, width: barW, height: barH)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 4),
                    with: .color(idx == splits.count - 1 ? .orange : .teal)
                )
            }
        }
    }
}
