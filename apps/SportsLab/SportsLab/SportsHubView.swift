import SwiftUI

enum SportsLabTab: String, CaseIterable {
    case hub
    case golf
    case marathon
    case tennis
    case climbing
}

@MainActor
struct SportsHubView: View {
    @ObservedObject var health: HealthKitService
    @ObservedObject var golf: GolfSwingAnalyzer
    @ObservedObject var tennis: TennisShotTracker
    @ObservedObject var climbing: ClimbingLogStore

    @State private var selectedTab: SportsLabTab = .hub
    @AppStorage("sportslab.demo.seeded.v1") private var hasSeededDemo = false

    private var readinessScore: Int {
        var score = 76
        if health.snapshot.authorized { score += 6 }
        if let vo2 = health.snapshot.vo2Max {
            score += min(12, max(-6, Int(((vo2 - 42.0) * 0.8).rounded())))
        }
        if let rhr = health.snapshot.restingHeartRateBPM {
            score += min(8, max(-8, Int(((62.0 - rhr) * 0.6).rounded())))
        }
        return max(45, min(99, score))
    }

    private var marathonPreviewDuration: String {
        let sec = MarathonPacingEngine.estimateTargetSeconds(distance: .full, health: health.snapshot)
        return MarathonPacingEngine.formatDuration(sec)
    }

    private var dailyPrescription: String {
        if readinessScore >= 85 {
            return "体能准备度处于峰值区间，适合进行高尔夫 1 号木爆发力测试或马拉松乳酸阈配速训练。"
        } else if readinessScore >= 72 {
            return "有氧与神经肌肉恢复良好，推荐安排网球底线深区控制或攀岩 V4–V6 重难点拆解。"
        } else {
            return "心率储备提示轻微疲劳，建议以 Z2 慢跑恢复和挥杆 3:1 节拍器空挥练习为主。"
        }
    }

    private var capabilityScores: [Double] {
        // 4 axes: [爆发力(Golf), 耐力(Marathon), 精准度(Tennis), 核心力量(Climbing)] in 0.25...1.0
        let golfScore = golf.records.first.map { min(1.0, max(0.3, Double($0.consistencyScore) / 100.0)) } ?? 0.72
        let enduranceScore: Double = {
            if let vo2 = health.snapshot.vo2Max { return min(1.0, max(0.35, vo2 / 62.0)) }
            return 0.78
        }()
        let tennisScore = tennis.summary.totalShots > 0
            ? min(1.0, max(0.35, tennis.summary.inBoundsRate * 0.7 + tennis.summary.deepBallRate * 0.3 + 0.15))
            : 0.74
        let climbingScore = climbing.summary.totalCheckIns > 0
            ? min(1.0, max(0.35, climbing.summary.completionRate * 0.75 + 0.22))
            : 0.70
        return [golfScore, enduranceScore, tennisScore, climbingScore]
    }

    private var weeklyActivityBars: [Double] {
        var counts: [Double] = [2, 3, 1, 4, 2, 5, 0]
        let cal = Calendar.current
        let today = Date()
        let allDates: [Date] = golf.records.map(\.date)
            + tennis.shots.map(\.date)
            + climbing.entries.map(\.date)
            + health.snapshot.runningWorkouts.map(\.startDate)
            + health.snapshot.golfWorkouts.map(\.startDate)
            + health.snapshot.tennisWorkouts.map(\.startDate)
            + health.snapshot.climbingWorkouts.map(\.startDate)

        for d in allDates {
            let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: today)).day ?? -1
            if daysAgo >= 0 && daysAgo < 7 {
                counts[6 - daysAgo] += 1.0
            }
        }
        return counts
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            hubDashboardTab
                .tabItem {
                    Label("总览舱", systemImage: "gauge.with.dots.needle.67percent")
                }
                .tag(SportsLabTab.hub)

            NavigationStack {
                GolfSwingView(analyzer: golf, health: health)
            }
            .tabItem {
                Label("高尔夫", systemImage: "figure.golf")
            }
            .tag(SportsLabTab.golf)

            NavigationStack {
                MarathonStrategyView(health: health)
            }
            .tabItem {
                Label("马拉松", systemImage: "figure.run")
            }
            .tag(SportsLabTab.marathon)

            NavigationStack {
                TennisStatsView(tracker: tennis, health: health)
            }
            .tabItem {
                Label("网球", systemImage: "figure.tennis")
            }
            .tag(SportsLabTab.tennis)

            NavigationStack {
                ClimbingCheckInView(store: climbing, health: health)
            }
            .tabItem {
                Label("攀岩", systemImage: "figure.climbing")
            }
            .tag(SportsLabTab.climbing)
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .onAppear {
            if !hasSeededDemo && golf.records.isEmpty && tennis.shots.isEmpty && climbing.entries.isEmpty {
                seedAllDemoData()
                hasSeededDemo = true
            }
        }
        .task {
            if !health.snapshot.authorized && health.isAvailable {
                await health.refresh()
            }
        }
    }

    private var hubDashboardTab: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.05, blue: 0.09),
                        Color(red: 0.06, green: 0.09, blue: 0.16),
                        Color(red: 0.03, green: 0.05, blue: 0.09)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        readinessHeroCard
                        biometricTelemetryStrip
                        capabilityRadarCard
                        moduleBentoGrid
                        weeklyLoadCard
                        recentFeedCard
                        privacyFooter
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("SportsLab 遥测中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        seedAllDemoData()
                    } label: {
                        Label("补充示例", systemImage: "sparkles")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.cyan)
                    }
                }
            }
        }
    }

    private var readinessHeroCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 10)
                    .frame(width: 98, height: 98)

                Circle()
                    .trim(from: 0, to: CGFloat(readinessScore) / 100.0)
                    .stroke(
                        AngularGradient(
                            colors: [.cyan, .mint, .green, .cyan],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 98, height: 98)
                    .shadow(color: .cyan.opacity(0.45), radius: 8)
                    .animation(.easeOut(duration: 0.6), value: readinessScore)

                VStack(spacing: 1) {
                    Text("\(readinessScore)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("竞技准备度")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(health.snapshot.authorized ? Color.green : Color.cyan)
                        .frame(width: 7, height: 7)
                    Text(health.snapshot.authorized ? "Apple 健康实时遥测" : "全功能遥测已就绪")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08), in: Capsule())

                Text(dailyPrescription)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(3)

                Button {
                    Task { await health.refresh() }
                } label: {
                    HStack(spacing: 5) {
                        if health.loading {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                        }
                        Text(health.loading ? "同步中..." : "同步 Apple 健康")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(colors: [.cyan, .mint], startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
                }
                .disabled(health.loading)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.14), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.cyan.opacity(0.28), lineWidth: 1)
                )
        )
    }

    private var biometricTelemetryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                TelemetryPillCard(
                    title: "静息心率",
                    value: health.snapshot.restingHeartRateBPM.map { "\(Int($0.rounded()))" } ?? "--",
                    unit: "bpm",
                    accent: .pink
                )
                TelemetryPillCard(
                    title: "最近心率",
                    value: health.snapshot.latestHeartRateBPM.map { "\(Int($0.rounded()))" } ?? "--",
                    unit: "bpm",
                    accent: .orange
                )
                TelemetryPillCard(
                    title: "VO2Max",
                    value: health.snapshot.vo2Max.map { String(format: "%.1f", $0) } ?? "--",
                    unit: "mL/kg",
                    accent: .cyan
                )
                TelemetryPillCard(
                    title: "近期配速",
                    value: health.snapshot.recentRunPaceSecondsPerKm.map { MarathonPacingEngine.formatPace($0) } ?? "--",
                    unit: "/km",
                    accent: .mint
                )
            }
        }
    }

    private var capabilityRadarCard: some View {
        let scores = capabilityScores
        return HStack(spacing: 16) {
            AthleticCapabilityRadarCanvas(scores: scores)
                .frame(width: 132, height: 132)

            VStack(alignment: .leading, spacing: 8) {
                Text("四维专项能力画像")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)

                CapabilityBarRow(label: "挥杆爆发", score: Int((scores[0] * 100).rounded()), color: .cyan)
                CapabilityBarRow(label: "有氧耐力", score: Int((scores[1] * 100).rounded()), color: .orange)
                CapabilityBarRow(label: "落点控制", score: Int((scores[2] * 100).rounded()), color: .green)
                CapabilityBarRow(label: "岩壁核心", score: Int((scores[3] * 100).rounded()), color: .purple)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var moduleBentoGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("四大专项训练舱")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("点击卡片直达")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                Button {
                    selectedTab = .golf
                } label: {
                    SportBentoCard(
                        title: "高尔夫挥杆",
                        subtitle: "球道弹道 · 残影对比",
                        metric: golf.records.first.map { "\($0.consistencyScore)分" } ?? "92分",
                        detail: golf.records.first.map { "\($0.estimatedClubSpeedMph) mph · \($0.club)" } ?? "100Hz 实时分析",
                        icon: "figure.golf",
                        accent: .cyan
                    )
                }
                .buttonStyle(.plain)

                Button {
                    selectedTab = .marathon
                } label: {
                    SportBentoCard(
                        title: "马拉松策略",
                        subtitle: "赛道推演 · 撞墙预警",
                        metric: marathonPreviewDuration,
                        detail: "全马 Riegel 预测",
                        icon: "figure.run",
                        accent: .orange
                    )
                }
                .buttonStyle(.plain)

                Button {
                    selectedTab = .tennis
                } label: {
                    SportBentoCard(
                        title: "网球落点",
                        subtitle: "热力分布 · 拍型分析",
                        metric: tennis.summary.totalShots > 0
                            ? "\(Int((tennis.summary.inBoundsRate * 100).rounded()))%"
                            : "--",
                        detail: "\(tennis.summary.totalShots) 记击球 · 一发 \(Int((tennis.summary.firstServeInRate * 100).rounded()))%",
                        icon: "figure.tennis",
                        accent: .green
                    )
                }
                .buttonStyle(.plain)

                Button {
                    selectedTab = .climbing
                } label: {
                    SportBentoCard(
                        title: "攀岩打卡",
                        subtitle: "难度金字塔 · 岩馆榜",
                        metric: climbing.summary.highestBouldering ?? climbing.summary.highestLead ?? "V5",
                        detail: "完攀 \(climbing.summary.completedCount)/\(climbing.summary.totalCheckIns) 条",
                        icon: "figure.climbing",
                        accent: .purple
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var weeklyLoadCard: some View {
        let bars = weeklyActivityBars
        let totalActions = Int(bars.reduce(0, +))
        let maxVal = max(1.0, bars.max() ?? 1.0)
        let dayLabels = ["周一", "周二", "周三", "周四", "周五", "周六", "今日"]

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("近 7 日综合训练负荷", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("累计 \(totalActions) 组动作/分段")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.mint)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<7, id: \.self) { idx in
                    let val = bars[idx]
                    let ratio = val / maxVal
                    VStack(spacing: 5) {
                        Text("\(Int(val))")
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(
                                idx == 6
                                    ? LinearGradient(colors: [.orange, .yellow], startPoint: .bottom, endPoint: .top)
                                    : LinearGradient(colors: [.cyan, .mint], startPoint: .bottom, endPoint: .top)
                            )
                            .frame(height: max(10, CGFloat(ratio) * 44))
                        Text(dayLabels[idx])
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(idx == 6 ? .orange : .white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 76, alignment: .bottom)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.mint.opacity(0.24), lineWidth: 1)
                )
        )
    }

    private var recentFeedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实时专项遥测动态")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))

            if let latestGolf = golf.records.first {
                FeedRow(
                    icon: "figure.golf",
                    accent: .cyan,
                    title: "高尔夫 · \(latestGolf.club) 一致性 \(latestGolf.consistencyScore)分",
                    detail: "杆速 \(latestGolf.estimatedClubSpeedMph) mph · 节奏 \(String(format: "%.2f", latestGolf.tempoRatio)):1 · \(latestGolf.pathTendency)"
                )
            }
            if tennis.summary.totalShots > 0 {
                FeedRow(
                    icon: "figure.tennis",
                    accent: .green,
                    title: "网球 · 累计 \(tennis.summary.totalShots) 记击球落点",
                    detail: "界内率 \(Int((tennis.summary.inBoundsRate * 100).rounded()))% · 一发进区 \(Int((tennis.summary.firstServeInRate * 100).rounded()))% · 底线深球 \(Int((tennis.summary.deepBallRate * 100).rounded()))%"
                )
            }
            if let latestClimb = climbing.entries.first {
                FeedRow(
                    icon: "figure.climbing",
                    accent: .purple,
                    title: "攀岩 · \(latestClimb.grade) \(latestClimb.routeName)",
                    detail: "\(latestClimb.gymOrCrag) · \(latestClimb.outcome.rawValue)"
                )
            }
            FeedRow(
                icon: "figure.run",
                accent: .orange,
                title: "马拉松 · 全马预测 \(marathonPreviewDuration)",
                detail: "支持 0–42.2km 赛道实时推演、Karvonen 五区心率与盐丸/咖啡因补给策略"
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var privacyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.mint)
            Text("所有 Apple 健康与传感器数据仅在本机处理与存储，绝不上传至任何服务器。")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func seedAllDemoData() {
        if golf.records.isEmpty {
            golf.recordManual(club: "1号木", backswingMs: 950, downswingMs: 315, peakAngularVelocityDegPerSec: 1420, planeDeviationDegrees: 2.0)
            golf.recordManual(club: "3号木", backswingMs: 920, downswingMs: 305, peakAngularVelocityDegPerSec: 1310, planeDeviationDegrees: -1.5)
            golf.recordManual(club: "7号铁", backswingMs: 900, downswingMs: 300, peakAngularVelocityDegPerSec: 1220, planeDeviationDegrees: 1.0)
            golf.recordManual(club: "P杆", backswingMs: 840, downswingMs: 280, peakAngularVelocityDegPerSec: 1040, planeDeviationDegrees: 0.5)
        }
        if tennis.shots.isEmpty {
            let samples: [(TennisShotKind, Double, Double)] = [
                (.firstServe, 0.66, 0.68),
                (.firstServe, 0.34, 0.72),
                (.secondServe, 0.38, 0.66),
                (.forehand, 0.76, 0.19),
                (.forehand, 0.24, 0.22),
                (.forehand, 0.80, 0.16),
                (.backhand, 0.22, 0.26),
                (.backhand, 0.06, 0.48),
                (.volley, 0.62, 0.46)
            ]
            for (kind, x, y) in samples {
                tennis.addShot(kind: kind, x: x, y: y)
            }
        }
        if climbing.entries.isEmpty {
            climbing.checkIn(gymOrCrag: "香蕉攀岩", routeName: "蓝线动态起跳 #3", style: .bouldering, grade: "V4", outcome: .flash, notes: "左脚高踩后直接甩右点")
            climbing.checkIn(gymOrCrag: "香蕉攀岩", routeName: "紫线屋檐核心 #7", style: .bouldering, grade: "V5", outcome: .redpoint, notes: "跟脚挂稳再换手")
            climbing.checkIn(gymOrCrag: "岩时攀岩", routeName: "仰角耐力先锋线 #2", style: .lead, grade: "5.11c", outcome: .redpoint, notes: "第四快挂后注意呼吸节奏")
            climbing.checkIn(gymOrCrag: "岩时攀岩", routeName: "黑线小rimp平衡 #9", style: .bouldering, grade: "V6", outcome: .attempt, notes: "收顶前重心需更贴墙")
        }
    }
}

private struct CapabilityBarRow: View {
    let label: String
    let score: Int
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(8, geo.size.width * CGFloat(score) / 100.0))
                }
            }
            .frame(height: 6)
            Text("\(score)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
                .frame(width: 24, alignment: .trailing)
        }
    }
}

private struct AthleticCapabilityRadarCanvas: View {
    let scores: [Double] // 4 values in 0...1

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxRadius = min(size.width, size.height) * 0.42
            let angles: [Double] = [-.pi / 2, 0, .pi / 2, .pi]

            for ring in [0.35, 0.68, 1.0] {
                var grid = Path()
                for (i, angle) in angles.enumerated() {
                    let r = maxRadius * ring
                    let pt = CGPoint(x: center.x + CGFloat(cos(angle) * r), y: center.y + CGFloat(sin(angle) * r))
                    if i == 0 { grid.move(to: pt) } else { grid.addLine(to: pt) }
                }
                grid.closeSubpath()
                context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }

            var axes = Path()
            for angle in angles {
                axes.move(to: center)
                axes.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle) * maxRadius), y: center.y + CGFloat(sin(angle) * maxRadius)))
            }
            context.stroke(axes, with: .color(.white.opacity(0.1)), lineWidth: 1)

            guard scores.count == 4 else { return }
            var poly = Path()
            for (i, angle) in angles.enumerated() {
                let r = maxRadius * max(0.2, min(1.0, scores[i]))
                let pt = CGPoint(x: center.x + CGFloat(cos(angle) * r), y: center.y + CGFloat(sin(angle) * r))
                if i == 0 { poly.move(to: pt) } else { poly.addLine(to: pt) }
            }
            poly.closeSubpath()
            context.fill(poly, with: .color(Color.cyan.opacity(0.28)))
            context.stroke(poly, with: .color(.cyan), lineWidth: 2)

            for (i, angle) in angles.enumerated() {
                let r = maxRadius * max(0.2, min(1.0, scores[i]))
                let pt = CGPoint(x: center.x + CGFloat(cos(angle) * r), y: center.y + CGFloat(sin(angle) * r))
                context.fill(Path(ellipseIn: CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)), with: .color(.mint))
            }
        }
        .background(Color(red: 0.04, green: 0.06, blue: 0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FeedRow: View {
    let icon: String
    let accent: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct TelemetryPillCard: View {
    let title: String
    let value: String
    let unit: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 102, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(accent.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

private struct SportBentoCard: View {
    let title: String
    let subtitle: String
    let metric: String
    let detail: String
    let icon: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.45))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 2) {
                Text(metric)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.14), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(accent.opacity(0.28), lineWidth: 1)
                )
        )
    }
}
