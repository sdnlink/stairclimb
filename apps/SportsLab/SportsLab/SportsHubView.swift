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
                        moduleBentoGrid
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

                Button {
                    Task { await health.refresh() }
                } label: {
                    HStack(spacing: 6) {
                        if health.loading {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                        }
                        Text(health.loading ? "同步中..." : "同步体能数据")
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
                        subtitle: "3D平面 · IMU分段",
                        metric: golf.records.first.map { "\($0.consistencyScore)分" } ?? "待采集",
                        detail: golf.records.first.map { "\($0.estimatedClubSpeedMph) mph" } ?? "100Hz 实时分析",
                        icon: "figure.golf",
                        accent: .cyan
                    )
                }

                NavigationLink {
                    MarathonStrategyView(health: health)
                } label: {
                    SportBentoCard(
                        title: "马拉松策略",
                        subtitle: "Riegel · 心率补给",
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
                        subtitle: "热区 · 一发成功率",
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
