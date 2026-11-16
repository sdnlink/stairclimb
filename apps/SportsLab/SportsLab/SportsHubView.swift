import SwiftUI

@MainActor
struct SportsHubView: View {
    @ObservedObject var health: HealthKitService
    @ObservedObject var golf: GolfSwingAnalyzer
    @ObservedObject var tennis: TennisShotTracker
    @ObservedObject var climbing: ClimbingLogStore

    private var readinessScore: Int {
        var score = 74
        if health.snapshot.authorized { score += 6 }
        if let vo2 = health.snapshot.vo2Max {
            score += min(12, max(-6, Int(((vo2 - 42.0) * 0.8).rounded())))
        }
        if let rhr = health.snapshot.restingHeartRateBPM {
            score += min(8, max(-8, Int(((62.0 - rhr) * 0.6).rounded())))
        }
        return max(40, min(99, score))
    }

    private var marathonPreviewDuration: String {
        let sec = MarathonPacingEngine.estimateTargetSeconds(distance: .full, health: health.snapshot)
        return MarathonPacingEngine.formatDuration(sec)
    }

    private var hasAnyLocalData: Bool {
        !golf.records.isEmpty || !tennis.shots.isEmpty || !climbing.entries.isEmpty
    }

    private var dailyPrescription: String {
        if readinessScore >= 85 {
            return "体能准备度极佳，适合安排高尔夫全挥杆爆发力训练或马拉松乳酸阈配速跑。"
        } else if readinessScore >= 70 {
            return "恢复状态良好，推荐进行网球底线多球落点或攀岩技术路线拆解。"
        } else {
            return "身体处于恢复期，建议以低强度有氧慢跑与高尔夫短杆/推杆节奏练习为主。"
        }
    }

    private var weeklyActivityBars: [Double] {
        // Map recent local + HealthKit workouts into 7 day buckets (Mon..Sun relative)
        var counts = Array(repeating: 0.0, count: 7)
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
                    VStack(spacing: 18) {
                        readinessHeroCard
                        biometricTelemetryStrip
                        weeklyLoadCard
                        moduleBentoGrid
                        recentFeedCard
                        privacyFooter
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("SportsLab")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                if !health.snapshot.authorized && health.isAvailable {
                    await health.refresh()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var readinessHeroCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 10)
                    .frame(width: 96, height: 96)

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
                    .frame(width: 96, height: 96)
                    .shadow(color: .cyan.opacity(0.45), radius: 8)
                    .animation(.easeOut(duration: 0.6), value: readinessScore)

                VStack(spacing: 1) {
                    Text("\(readinessScore)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("准备度")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(health.snapshot.authorized ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(health.snapshot.authorized ? "Apple 健康已同步" : "本地体能模式")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08), in: Capsule())

                Text(health.snapshot.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)

                HStack(spacing: 8) {
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
                            Text(health.loading ? "同步中" : "同步健康")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            LinearGradient(colors: [.cyan, .mint], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                    }
                    .disabled(health.loading)

                    if !hasAnyLocalData {
                        Button {
                            seedAllDemoData()
                        } label: {
                            Text("载入全套示例")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.14), in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
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

    private var weeklyLoadCard: some View {
        let bars = weeklyActivityBars
        let totalActions = Int(bars.reduce(0, +))
        let maxVal = max(1.0, bars.max() ?? 1.0)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("近 7 日专项负荷与处方", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(totalActions) 次记录")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.mint)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<7, id: \.self) { idx in
                    let val = bars[idx]
                    let ratio = val / maxVal
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                val > 0
                                    ? LinearGradient(colors: [.cyan, .mint], startPoint: .bottom, endPoint: .top)
                                    : LinearGradient(colors: [Color.white.opacity(0.1), Color.white.opacity(0.1)], startPoint: .bottom, endPoint: .top)
                            )
                            .frame(height: max(6, CGFloat(ratio) * 38))
                        Text(idx == 6 ? "今日" : "-\(6 - idx)d")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 54, alignment: .bottom)

            Text(dailyPrescription)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
                .lineSpacing(2)
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

    private var moduleBentoGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专项实验室")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                NavigationLink {
                    GolfSwingView(analyzer: golf, health: health)
                } label: {
                    SportBentoCard(
                        title: "高尔夫挥杆",
                        subtitle: "3D平面 · 残影对比",
                        metric: golf.records.first.map { "\($0.consistencyScore)分" } ?? "待采集",
                        detail: golf.records.first.map { "\($0.estimatedClubSpeedMph) mph · \($0.club)" } ?? "100Hz 实时分析",
                        icon: "figure.golf",
                        accent: .cyan
                    )
                }

                NavigationLink {
                    MarathonStrategyView(health: health)
                } label: {
                    SportBentoCard(
                        title: "马拉松策略",
                        subtitle: "Riegel · 撞墙预警",
                        metric: marathonPreviewDuration,
                        detail: "全马预测完赛",
                        icon: "figure.run",
                        accent: .orange
                    )
                }

                NavigationLink {
                    TennisStatsView(tracker: tennis, health: health)
                } label: {
                    SportBentoCard(
                        title: "网球落点",
                        subtitle: "热区 · 深球统计",
                        metric: tennis.summary.totalShots > 0
                            ? "\(Int((tennis.summary.inBoundsRate * 100).rounded()))%"
                            : "--",
                        detail: "\(tennis.summary.totalShots) 记击球记录",
                        icon: "figure.tennis",
                        accent: .green
                    )
                }

                NavigationLink {
                    ClimbingCheckInView(store: climbing, health: health)
                } label: {
                    SportBentoCard(
                        title: "攀岩打卡",
                        subtitle: "抱石 · 先锋路线",
                        metric: climbing.summary.highestBouldering ?? climbing.summary.highestLead ?? "V0",
                        detail: "完攀 \(climbing.summary.completedCount) 条",
                        icon: "figure.climbing",
                        accent: .purple
                    )
                }
            }
        }
    }

    private var recentFeedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近专项动态")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))

            if !hasAnyLocalData && health.snapshot.runningWorkouts.isEmpty {
                Text("暂无训练动态，点击上方「载入全套示例」或进入任意实验室开始记录。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                if let latestGolf = golf.records.first {
                    FeedRow(
                        icon: "figure.golf",
                        accent: .cyan,
                        title: "高尔夫 · \(latestGolf.club) \(latestGolf.consistencyScore)分",
                        detail: "\(latestGolf.estimatedClubSpeedMph) mph · 节奏 \(String(format: "%.2f", latestGolf.tempoRatio)):1"
                    )
                }
                if tennis.summary.totalShots > 0 {
                    FeedRow(
                        icon: "figure.tennis",
                        accent: .green,
                        title: "网球 · 本场 \(tennis.summary.totalShots) 记击球",
                        detail: "界内率 \(Int((tennis.summary.inBoundsRate * 100).rounded()))% · 底线深球 \(Int((tennis.summary.deepBallRate * 100).rounded()))%"
                    )
                }
                if let latestClimb = climbing.entries.first {
                    FeedRow(
                        icon: "figure.climbing",
                        accent: .purple,
                        title: "攀岩 · \(latestClimb.grade) \(latestClimb.routeName)",
                        detail: "\(latestClimb.gymOrCrag) · \(latestClimb.outcome.isCompleted ? "完攀" : "尝试")"
                    )
                }
                if let latestRun = health.snapshot.runningWorkouts.first {
                    let km = latestRun.distanceMeters.map { String(format: "%.1f km", $0 / 1000.0) } ?? "跑步"
                    FeedRow(
                        icon: "figure.run",
                        accent: .orange,
                        title: "Apple 健康跑步 · \(km)",
                        detail: "用时 \(MarathonPacingEngine.formatDuration(latestRun.durationSeconds))"
                    )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            golf.recordManual(club: "1号木", backswingMs: 960, downswingMs: 315, peakAngularVelocityDegPerSec: 1420, planeDeviationDegrees: 2.0)
            golf.recordManual(club: "3号木", backswingMs: 930, downswingMs: 310, peakAngularVelocityDegPerSec: 1310, planeDeviationDegrees: 2.5)
            golf.recordManual(club: "7号铁", backswingMs: 900, downswingMs: 300, peakAngularVelocityDegPerSec: 1220, planeDeviationDegrees: 1.5)
            golf.recordManual(club: "P杆", backswingMs: 850, downswingMs: 290, peakAngularVelocityDegPerSec: 1020, planeDeviationDegrees: 1.0)
        }
        if tennis.shots.isEmpty {
            let samples: [(TennisShotKind, Double, Double)] = [
                (.firstServe, 0.66, 0.68),
                (.firstServe, 0.34, 0.72),
                (.forehand, 0.76, 0.19),
                (.forehand, 0.24, 0.22),
                (.backhand, 0.22, 0.26),
                (.volley, 0.62, 0.46)
            ]
            for (kind, x, y) in samples {
                tennis.addShot(kind: kind, x: x, y: y)
            }
        }
        if climbing.entries.isEmpty {
            climbing.checkIn(gymOrCrag: "香蕉攀岩", routeName: "蓝线动态起跳 #3", style: .bouldering, grade: "V4", outcome: .flash, notes: "左脚高踩后直接甩右点")
            climbing.checkIn(gymOrCrag: "香蕉攀岩", routeName: "紫线屋檐 #7", style: .bouldering, grade: "V5", outcome: .redpoint, notes: "跟脚挂稳再换手")
        }
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
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
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
