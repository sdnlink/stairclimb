import SwiftUI

struct MarathonStrategyView: View {
    @ObservedObject var health: HealthKitService

    @State private var distance: MarathonDistance = .full
    @State private var strategy: PacingStrategyMode = .negativeSplit
    @State private var targetMinutes: Double = 225
    @State private var bodyWeightKg: Double = 68
    @State private var temperatureCelsius: Double = 22
    @State private var elevationGainMeters: Double = 180
    @State private var runnerAge: Int = 32
    @State private var hasAppliedHealthEstimate = false
    @State private var selectedSplitIndex: Int = 0
    @State private var showCourseTuner = false
    @State private var simulatedKm: Double = 21.0
    @State private var checkedGear: Set<String> = ["能量胶与盐丸", "号码布与计时芯片"]

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
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.09),
                    Color(red: 0.07, green: 0.08, blue: 0.14),
                    Color(red: 0.03, green: 0.05, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    heroFinishCard
                    bonkRiskCard
                    distanceAndStrategyBar
                    raceSimulatorCard
                    interactiveSplitRibbonCard
                    splitTableCard
                    hrZonesSpectrumCard
                    packingKitGrid
                    fuelingTimelineCard
                    preRaceChecklistCard
                    healthRiegelStrip
                    courseTunerDrawer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("马拉松战术舱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareSummaryText) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !hasAppliedHealthEstimate {
                let sec = MarathonPacingEngine.estimateTargetSeconds(distance: distance, health: health.snapshot)
                targetMinutes = (sec / 60.0).rounded()
                hasAppliedHealthEstimate = true
            }
        }
        .onChange(of: distance) { _, newDistance in
            let sec = MarathonPacingEngine.estimateTargetSeconds(distance: newDistance, health: health.snapshot)
            targetMinutes = (sec / 60.0).rounded()
            selectedSplitIndex = 0
            simulatedKm = min(simulatedKm, newDistance.kilometers)
        }
    }

    private var heroFinishCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("预计完赛时间")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(MarathonPacingEngine.formatDuration(plan.targetTotalSeconds))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("平均配速")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("\(MarathonPacingEngine.formatPace(plan.averagePaceSecondsPerKm))/km")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                    if plan.elevationPenaltySecondsPerKm > 0.1 {
                        Text("爬升 +\(String(format: "%.1f", plan.elevationPenaltySecondsPerKm))s/km")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.yellow)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.cyan)
                Text(plan.healthBasisNote)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: Capsule())
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.orange.opacity(0.18), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.orange.opacity(0.32), lineWidth: 1)
                )
        )
    }

    private var bonkRiskAssessment: (level: String, color: Color, tip: String) {
        var riskPoints = 0
        if temperatureCelsius >= 26 { riskPoints += 2 } else if temperatureCelsius >= 22 { riskPoints += 1 }
        if elevationGainMeters >= 400 { riskPoints += 2 } else if elevationGainMeters >= 200 { riskPoints += 1 }
        if distance == .full {
            let longestKm = (health.snapshot.runningWorkouts.compactMap(\.distanceMeters).max() ?? 0) / 1000.0
            if longestKm > 0 && longestKm < 24 { riskPoints += 2 }
        }
        if riskPoints >= 4 {
            return ("高撞墙风险", .red, "高温/爬升或长距离储备偏少，建议切换「稳健起步防掉速」并将前 10km 压慢 5-8s/km。")
        } else if riskPoints >= 2 {
            return ("中等风险", .yellow, "注意前程心率勿冲过 Z4，30km 后按时间轴补足咖啡因与电解质钠。")
        } else {
            return ("低风险 · 状态稳健", .mint, "赛道与体能匹配度良好，可按既定分段配速推进。")
        }
    }

    private var bonkRiskCard: some View {
        let risk = bonkRiskAssessment
        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(risk.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("后程撞墙评估：\(risk.level)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(risk.color)
                Text(risk.tip)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(risk.color.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(risk.color.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var shareSummaryText: String {
        let splitLines = plan.splits.map {
            "\($0.segmentLabel): \(MarathonPacingEngine.formatPace($0.paceSecondsPerKm))/km (累计 \(MarathonPacingEngine.formatDuration($0.cumulativeSeconds)))"
        }.joined(separator: "\n")
        return """
        SportsLab 马拉松比赛日战术卡
        项目：\(distance.rawValue) · \(strategy.rawValue)
        目标完赛：\(MarathonPacingEngine.formatDuration(plan.targetTotalSeconds))（均速 \(MarathonPacingEngine.formatPace(plan.averagePaceSecondsPerKm))/km）
        赛前清单：\(plan.totalGelsCount) 支能量胶 · \(plan.totalWaterMl) mL 补水 · \(plan.totalSodiumMg) mg 钠盐
        分段配速：
        \(splitLines)
        """
    }

    private var distanceAndStrategyBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(MarathonDistance.allCases) { d in
                    let active = distance == d
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            distance = d
                        }
                    } label: {
                        Text(d == .half ? "半程 21.1K" : "全程 42.2K")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(active ? .black : .white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(active ? Color.orange : Color.white.opacity(0.07), in: Capsule())
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PacingStrategyMode.allCases) { mode in
                        let active = strategy == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                strategy = mode
                            }
                        } label: {
                            Text(mode.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(active ? .black : .white.opacity(0.75))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(active ? Color.cyan : Color.white.opacity(0.07), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private var interactiveSplitRibbonCard: some View {
        let safeIndex = min(selectedSplitIndex, max(0, plan.splits.count - 1))
        let focusedSplit = plan.splits.indices.contains(safeIndex) ? plan.splits[safeIndex] : nil

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("分段配速与心率带")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("点击节点查看详情")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }

            RaceCourseSplitCanvas(splits: plan.splits, selectedIndex: safeIndex)
                .frame(height: 118)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(plan.splits.enumerated()), id: \.element.id) { idx, split in
                        let selected = idx == safeIndex
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedSplitIndex = idx
                            }
                        } label: {
                            Text(split.segmentLabel)
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(selected ? .black : .white.opacity(0.75))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selected ? Color.orange : Color.white.opacity(0.07), in: Capsule())
                        }
                    }
                }
            }

            if let split = focusedSplit {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(split.segmentLabel) · \(split.zoneLabel)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.cyan)
                        Text("累计用时 \(MarathonPacingEngine.formatDuration(split.cumulativeSeconds))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(MarathonPacingEngine.formatPace(split.paceSecondsPerKm))/km")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                        if let hr = split.targetHRRange {
                            Text("心率 \(hr.lowerBound)-\(hr.upperBound) bpm")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private var splitTableCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("全程分段配速总表")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(plan.splits.count) 段")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }

            ForEach(Array(plan.splits.enumerated()), id: \.element.id) { idx, split in
                let isSelected = idx == min(selectedSplitIndex, max(0, plan.splits.count - 1))
                HStack(spacing: 8) {
                    Text(split.segmentLabel)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(isSelected ? .orange : .white)
                        .frame(width: 72, alignment: .leading)
                    Text("\(MarathonPacingEngine.formatPace(split.paceSecondsPerKm))/km")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.cyan)
                    Spacer()
                    if let hr = split.targetHRRange {
                        Text("\(hr.lowerBound)-\(hr.upperBound) bpm")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Text(MarathonPacingEngine.formatDuration(split.cumulativeSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    isSelected ? Color.orange.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .onTapGesture {
                    selectedSplitIndex = idx
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private var packingKitGrid: some View {
        HStack(spacing: 10) {
            PackingTile(title: "能量胶", value: "\(plan.totalGelsCount)", unit: "支", accent: .orange, icon: "flame.fill")
            PackingTile(title: "预计补水", value: "\(plan.totalWaterMl)", unit: "mL", accent: .cyan, icon: "drop.fill")
            PackingTile(title: "电解质钠", value: "\(plan.totalSodiumMg)", unit: "mg", accent: .purple, icon: "bolt.fill")
        }
    }

    private var raceSimulatorCard: some View {
        let clampedKm = min(distance.kilometers, max(1.0, simulatedKm))
        let elapsedSec = (clampedKm / distance.kilometers) * plan.targetTotalSeconds
        let activeSplit = plan.splits.first(where: { $0.distanceKm >= clampedKm }) ?? plan.splits.last
        let passedCues = plan.fuelingCues.filter { $0.distanceKm <= clampedKm }
        let nextCue = plan.fuelingCues.first(where: { $0.distanceKm > clampedKm })
        let carbsTaken = passedCues.map(\.carbsGrams).reduce(0, +)
        let waterTaken = passedCues.map(\.waterMl).reduce(0, +)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("赛道进程实时推演", systemImage: "figure.run.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.1f / %.1f km", clampedKm, distance.kilometers))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange)
            }

            Slider(value: $simulatedKm, in: 1.0...distance.kilometers, step: 0.5)
                .tint(.orange)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("经过用时")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(MarathonPacingEngine.formatDuration(elapsedSec))
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前配速")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                    Text("\(MarathonPacingEngine.formatPace(activeSplit?.paceSecondsPerKm ?? plan.averagePaceSecondsPerKm))/km")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(.cyan)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("已摄入碳水/水")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                    Text("\(carbsTaken)g · \(waterTaken)mL")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(.mint)
                }
            }

            if let next = nextCue {
                Text("下一补给站：\(String(format: "%.1f", next.distanceKm)) km（第 \(next.minuteMark) 分钟 · \(next.action)）")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text("已完成全部赛道补给节点，保持核心稳定冲线！")
                    .font(.caption2)
                    .foregroundStyle(.mint)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.orange.opacity(0.26), lineWidth: 1)
                )
        )
    }

    private var hrZonesSpectrumCard: some View {
        let rhr = health.snapshot.restingHeartRateBPM ?? 56.0
        let zones: [(name: String, low: Double, high: Double, color: Color)] = [
            ("Z1 热身恢复", 0.55, 0.65, .blue),
            ("Z2 有氧耐力底", 0.65, 0.75, .mint),
            ("Z3 马拉松巡航", 0.75, 0.83, .cyan),
            ("Z4 乳酸阈维持", 0.83, 0.90, .orange),
            ("Z5 无氧极限", 0.90, 0.98, .red)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Karvonen 储备心率五区光谱", systemImage: "heart.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.pink)
                Spacer()
                Text("静息 \(Int(rhr.rounded())) bpm · \(runnerAge)岁")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }

            ForEach(zones, id: \.name) { z in
                let range = MarathonPacingEngine.karvonenHeartRateRange(
                    restingHR: rhr,
                    age: runnerAge,
                    intensityLow: z.low,
                    intensityHigh: z.high
                )
                HStack(spacing: 8) {
                    Circle().fill(z.color).frame(width: 8, height: 8)
                    Text(z.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 86, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(z.color.opacity(0.75))
                            .frame(width: geo.size.width * CGFloat(z.high), height: 8)
                    }
                    .frame(height: 8)
                    Text(range.map { "\($0.lowerBound)–\($0.upperBound) bpm" } ?? "--")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(z.color)
                        .frame(width: 82, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var preRaceChecklistCard: some View {
        let items = [
            "能量胶与盐丸（按清单装入腰包）",
            "号码布与计时芯片固定",
            "运动手表/心率带充满电",
            "重点部位防磨凡士林涂抹",
            "起跑前 45 分钟慢饮 250mL 电解质水"
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("赛前装备与补给核对单", systemImage: "checklist")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(checkedGear.count)/\(items.count) 已就绪")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.mint)
            }

            ForEach(items, id: \.self) { item in
                let checked = checkedGear.contains(item)
                Button {
                    if checked { checkedGear.remove(item) } else { checkedGear.insert(item) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(checked ? .mint : .white.opacity(0.4))
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(checked ? .white : .white.opacity(0.7))
                            .strikethrough(checked, color: .mint)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var fuelingTimelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("赛中补给时间轴")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(plan.carbsPerHourGrams)g 碳水/h · \(plan.sodiumPerHourMg)mg 钠/h")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.cyan)
            }

            ForEach(Array(plan.fuelingCues.enumerated()), id: \.element.id) { idx, cue in
                let isCaffeine = cue.action.contains("咖啡因")
                let accent: Color = isCaffeine ? .purple : .orange

                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(accent.opacity(0.22))
                                .frame(width: 28, height: 28)
                            Image(systemName: isCaffeine ? "bolt.fill" : "flame.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(accent)
                        }
                        if idx < plan.fuelingCues.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 2, height: 24)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(cue.minuteMark) 分钟")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(accent)
                            Text("· \(String(format: "%.1f", cue.distanceKm)) km")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            Text("+\(cue.carbsGrams)g 碳水 · \(cue.waterMl)mL")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Text(cue.action)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private var healthRiegelStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Health 近期跑步（点击代入 Riegel 预测）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            if health.snapshot.runningWorkouts.isEmpty {
                Text("暂无近期跑步记录（可在首页同步 Apple 健康）")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(health.snapshot.runningWorkouts) { run in
                            Button {
                                if let meters = run.distanceMeters, meters > 500 {
                                    let predicted = MarathonPacingEngine.riegelPredictSeconds(
                                        knownDistanceKm: meters / 1000.0,
                                        knownDurationSeconds: run.durationSeconds,
                                        targetDistance: distance
                                    )
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        targetMinutes = max(75, min(390, (predicted / 60.0).rounded()))
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(run.startDate.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.6))
                                    Text(run.distanceMeters.map { String(format: "%.1f km", $0 / 1000.0) } ?? "--")
                                        .font(.subheadline.monospacedDigit().weight(.bold))
                                        .foregroundStyle(.cyan)
                                    Text(MarathonPacingEngine.formatDuration(run.durationSeconds))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
                                        )
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var courseTunerDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showCourseTuner.toggle()
                }
            } label: {
                HStack {
                    Label("赛道与体能参数设置", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: showCourseTuner ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if showCourseTuner {
                VStack(alignment: .leading, spacing: 10) {
                    TunerSlider(title: "目标时间", valueText: "\(Int(targetMinutes)) 分钟", value: $targetMinutes, range: 75...390, step: 1, tint: .orange)
                    TunerSlider(title: "累计爬升", valueText: "\(Int(elevationGainMeters)) m", value: $elevationGainMeters, range: 0...1500, step: 20, tint: .yellow)
                    TunerSlider(title: "跑者体重", valueText: "\(Int(bodyWeightKg)) kg", value: $bodyWeightKg, range: 45...105, step: 1, tint: .cyan)
                    TunerSlider(title: "比赛气温", valueText: "\(Int(temperatureCelsius)) ℃", value: $temperatureCelsius, range: 5...36, step: 1, tint: .mint)
                    Stepper("跑者年龄：\(runnerAge) 岁", value: $runnerAge, in: 18...75)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

private struct PackingTile: View {
    let title: String
    let value: String
    let unit: String
    let accent: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(accent)
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(accent.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

private struct TunerSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
            }
            Slider(value: $value, in: range, step: step)
                .tint(tint)
        }
    }
}

private struct RaceCourseSplitCanvas: View {
    let splits: [MarathonSplit]
    let selectedIndex: Int

    var body: some View {
        Canvas { context, size in
            guard !splits.isEmpty else { return }
            let paces = splits.map(\.paceSecondsPerKm)
            let minPace = (paces.min() ?? 240) - 12
            let maxPace = max(minPace + 10, (paces.max() ?? 360) + 8)
            let count = splits.count
            let slotWidth = size.width / CGFloat(count)
            let barWidth = max(12, slotWidth * 0.56)

            for (idx, split) in splits.enumerated() {
                let norm = (split.paceSecondsPerKm - minPace) / (maxPace - minPace)
                let height = max(16, CGFloat(0.28 + 0.65 * norm) * (size.height - 14))
                let x = CGFloat(idx) * slotWidth + (slotWidth - barWidth) / 2
                let y = size.height - height - 6
                let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                let barColor: Color = split.zoneLabel.contains("Z4")
                    ? .orange
                    : (split.zoneLabel.contains("Z3") ? .cyan : .mint)
                let opacity: Double = idx == selectedIndex ? 1.0 : 0.48
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 5),
                    with: .color(barColor.opacity(opacity))
                )
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.04, green: 0.06, blue: 0.11))
        )
    }
}
