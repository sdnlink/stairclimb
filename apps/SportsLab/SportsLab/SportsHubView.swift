import SwiftUI

@MainActor
struct SportsHubView: View {
    @ObservedObject var health: HealthKitService
    @ObservedObject var golf: GolfSwingAnalyzer
    @ObservedObject var tennis: TennisShotTracker
    @ObservedObject var climbing: ClimbingLogStore
    @ObservedObject var freedive: FreediveApneaTrainer

    var body: some View {
        NavigationStack {
            List {
                Section("Apple 健康体能概览") {
                    Text(health.snapshot.statusMessage).font(.subheadline)
                    if let rhr = health.snapshot.restingHeartRateBPM {
                        LabeledContent("静息心率", value: "\(Int(rhr.rounded())) bpm")
                    }
                    if let hr = health.snapshot.latestHeartRateBPM {
                        LabeledContent("最近心率", value: "\(Int(hr.rounded())) bpm")
                    }
                    if let vo2 = health.snapshot.vo2Max {
                        LabeledContent("最大摄氧量 (VO2Max)", value: String(format: "%.1f", vo2))
                    }
                    if let pace = health.snapshot.recentRunPaceSecondsPerKm {
                        LabeledContent("近期跑步配速", value: "\(MarathonPacingEngine.formatPace(pace))/km")
                    }
                    Button {
                        Task { await health.refresh() }
                    } label: {
                        HStack {
                            Label("同步 Apple 健康数据", systemImage: "heart.text.square")
                            if health.loading {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(health.loading)
                }

                Section("专项运动模块") {
                    NavigationLink {
                        GolfSwingView(analyzer: golf, health: health)
                    } label: {
                        Label("高尔夫挥杆轨迹分析", systemImage: "figure.golf")
                    }
                    NavigationLink {
                        TennisStatsView(tracker: tennis, health: health)
                    } label: {
                        Label("网球击球落点统计", systemImage: "figure.tennis")
                    }
                    NavigationLink {
                        ClimbingCheckInView(store: climbing, health: health)
                    } label: {
                        Label("攀岩路线打卡", systemImage: "figure.climbing")
                    }
                    NavigationLink {
                        FreediveTrainerView(trainer: freedive, health: health)
                    } label: {
                        Label("自由潜闭气训练", systemImage: "lungs")
                    }
                    NavigationLink {
                        MarathonStrategyView(health: health)
                    } label: {
                        Label("马拉松配速与补给策略", systemImage: "figure.run")
                    }
                }

                Section("隐私与安全说明") {
                    Text("所有 Apple 健康数据及专项训练记录仅在本机处理与存储，不上传至任何服务器，也不用于广告或追踪。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("运动实验室")
            .task {
                if !health.snapshot.authorized && health.isAvailable {
                    await health.refresh()
                }
            }
        }
    }
}
