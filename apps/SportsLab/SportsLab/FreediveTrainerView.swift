import SwiftUI

@MainActor
struct FreediveTrainerView: View {
    @ObservedObject var trainer: FreediveApneaTrainer
    @ObservedObject var health: HealthKitService
    @State private var confirmSafety = false

    var body: some View {
        List {
            Section("体能参考与安全提示") {
                Text(FreediveApneaTrainer.recoveryAdvice(restingHeartRateBPM: health.snapshot.restingHeartRateBPM))
                    .font(.subheadline)
                Text("仅限干式陆地训练使用；切勿在无专业潜伴看护的水中独自进行闭气训练。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section("训练表配置") {
                Picker("训练模式", selection: $trainer.tableKind) {
                    ForEach(ApneaTableKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(trainer.phase != .idle && trainer.phase != .finished)
                .onChange(of: trainer.tableKind) { _, _ in trainer.rebuildTable() }

                Stepper("个人最大闭气 (PB): \(trainer.personalBestSeconds) 秒", value: $trainer.personalBestSeconds, in: 45...360, step: 15)
                    .disabled(trainer.phase != .idle && trainer.phase != .finished)
                    .onChange(of: trainer.personalBestSeconds) { _, _ in trainer.rebuildTable() }
            }

            Section("实时闭气计时") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phaseTitle).font(.headline).foregroundStyle(trainer.phase == .holding ? .red : .primary)
                        if trainer.phase == .resting || trainer.phase == .holding {
                            Text("第 \(trainer.currentRoundIndex + 1) / \(trainer.rounds.count) 轮")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(trainer.remainingSeconds)s").font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                }
                if trainer.phase == .holding {
                    Button("记录首次横膈膜抽动 (\(trainer.elapsedInHoldSeconds)s)") { trainer.markContraction() }
                        .disabled(trainer.firstContractionSecond != nil)
                }
                if let c = trainer.firstContractionSecond {
                    Text("首次抽动时间点：\(c) 秒").font(.caption).foregroundStyle(.secondary)
                }
                if trainer.phase == .idle || trainer.phase == .finished {
                    Button("开始干式闭气训练") { confirmSafety = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("停止训练", role: .destructive) { trainer.stop(saveIfFinished: false) }
                }
            }

            Section("训练轮次明细") {
                ForEach(trainer.rounds) { round in
                    HStack {
                        Text("第 \(round.index) 轮")
                        Spacer()
                        Text("呼吸 \(round.restSeconds)s · 闭气 \(round.holdSeconds)s").font(.caption.monospacedDigit())
                    }
                }
            }

            if !trainer.logs.isEmpty {
                Section("历史闭气记录") {
                    ForEach(trainer.logs.prefix(10)) { log in
                        HStack {
                            Text("\(log.tableKind.rawValue) · 峰值 \(log.maxHoldCompletedSeconds)s")
                            Spacer()
                            if let c = log.firstContractionSecond {
                                Text("抽动 \(c)s").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("自由潜闭气训练")
        .alert("安全须知与免责声明", isPresented: $confirmSafety) {
            Button("我已确认在陆地安全环境") {
                trainer.start(restingHeartRateBPM: health.snapshot.restingHeartRateBPM)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本功能仅作干式陆地闭气节奏计时参考，非医疗器械，严禁在水中或无专业潜伴看护时独自使用。")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("同步健康") { Task { await health.refresh() } }.disabled(health.loading)
            }
        }
    }

    private var phaseTitle: String {
        switch trainer.phase {
        case .idle: "准备就绪"
        case .resting: "恢复呼吸阶段"
        case .holding: "闭气阶段"
        case .finished: "本组训练已完成"
        }
    }
}
