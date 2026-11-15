import Foundation

enum ApneaTableKind: String, Codable, CaseIterable, Identifiable {
    case co2 = "CO2 耐受表"
    case o2 = "O2 低氧表"
    var id: String { rawValue }
}

struct ApneaRound: Equatable, Identifiable {
    let index: Int
    let restSeconds: Int
    let holdSeconds: Int
    var id: Int { index }
}

enum ApneaPhase: Equatable {
    case idle, resting, holding, finished
}

struct ApneaSessionLog: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let tableKind: ApneaTableKind
    let maxHoldCompletedSeconds: Int
    let firstContractionSecond: Int?
    let restingHeartRateBPM: Double?
}

@MainActor
final class FreediveApneaTrainer: ObservableObject {
    @Published var tableKind: ApneaTableKind = .co2
    @Published var personalBestSeconds: Int = 120
    @Published private(set) var rounds: [ApneaRound] = []
    @Published private(set) var currentRoundIndex: Int = 0
    @Published private(set) var phase: ApneaPhase = .idle
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var elapsedInHoldSeconds: Int = 0
    @Published private(set) var firstContractionSecond: Int? = nil
    @Published private(set) var logs: [ApneaSessionLog] = []

    private var timerTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let storageKey = "sports.freedive.apnea.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        rebuildTable()
    }

    static func buildTable(kind: ApneaTableKind, personalBestSeconds: Int, roundsCount: Int = 8) -> [ApneaRound] {
        let pb = max(40, min(420, personalBestSeconds))
        let count = max(4, min(10, roundsCount))
        switch kind {
        case .co2:
            let fixedHold = Int((Double(pb) * 0.5).rounded())
            return (0..<count).map { idx in ApneaRound(index: idx + 1, restSeconds: max(30, 120 - idx * 12), holdSeconds: fixedHold) }
        case .o2:
            let startHold = Int((Double(pb) * 0.4).rounded())
            let targetHold = Int((Double(pb) * 0.8).rounded())
            let step = count > 1 ? (targetHold - startHold) / (count - 1) : 0
            return (0..<count).map { idx in ApneaRound(index: idx + 1, restSeconds: 120, holdSeconds: startHold + idx * step) }
        }
    }

    static func recoveryAdvice(restingHeartRateBPM: Double?) -> String {
        guard let rhr = restingHeartRateBPM else {
            return "未获取到 Apple 健康静息心率，建议每次训练前静坐深呼吸 3 分钟至心率平稳。"
        }
        if rhr > 75 {
            return "今日静息心率偏高（\(Int(rhr)) bpm），建议降低闭气目标至 PB 的 45% 并以放松呼吸为主。"
        }
        return "今日静息心率良好（\(Int(rhr)) bpm），适合按标准干式闭气表循序渐进训练。"
    }

    func rebuildTable() {
        rounds = Self.buildTable(kind: tableKind, personalBestSeconds: personalBestSeconds)
    }

    func start(restingHeartRateBPM: Double?) {
        stop(saveIfFinished: false)
        rebuildTable()
        guard let first = rounds.first else { return }
        currentRoundIndex = 0
        firstContractionSecond = nil
        elapsedInHoldSeconds = 0
        phase = .resting
        remainingSeconds = first.restSeconds
        timerTask = Task { [weak self] in await self?.runLoop(restingHeartRateBPM: restingHeartRateBPM) }
    }

    func markContraction() {
        guard phase == .holding, firstContractionSecond == nil else { return }
        firstContractionSecond = elapsedInHoldSeconds
    }

    func stop(saveIfFinished: Bool = false) {
        timerTask?.cancel()
        timerTask = nil
        if saveIfFinished, let maxHold = rounds.map(\.holdSeconds).max() {
            logs.insert(ApneaSessionLog(id: UUID(), date: Date(), tableKind: tableKind, maxHoldCompletedSeconds: maxHold, firstContractionSecond: firstContractionSecond, restingHeartRateBPM: nil), at: 0)
            save()
        }
        phase = .idle
        remainingSeconds = 0
        elapsedInHoldSeconds = 0
    }

    private func runLoop(restingHeartRateBPM: Double?) async {
        while !Task.isCancelled && phase != .idle && phase != .finished {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            if Task.isCancelled { return }
            if remainingSeconds > 1 {
                remainingSeconds -= 1
                if phase == .holding { elapsedInHoldSeconds += 1 }
            } else {
                advancePhase(restingHeartRateBPM: restingHeartRateBPM)
            }
        }
    }

    private func advancePhase(restingHeartRateBPM: Double?) {
        guard currentRoundIndex < rounds.count else { phase = .finished; return }
        let round = rounds[currentRoundIndex]
        switch phase {
        case .resting:
            phase = .holding
            remainingSeconds = round.holdSeconds
            elapsedInHoldSeconds = 0
        case .holding:
            if currentRoundIndex + 1 < rounds.count {
                currentRoundIndex += 1
                phase = .resting
                remainingSeconds = rounds[currentRoundIndex].restSeconds
                elapsedInHoldSeconds = 0
            } else {
                phase = .finished
                remainingSeconds = 0
                logs.insert(ApneaSessionLog(id: UUID(), date: Date(), tableKind: tableKind, maxHoldCompletedSeconds: round.holdSeconds, firstContractionSecond: firstContractionSecond, restingHeartRateBPM: restingHeartRateBPM), at: 0)
                save()
            }
        case .idle, .finished:
            break
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(logs) { defaults.set(data, forKey: storageKey) }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([ApneaSessionLog].self, from: data) else { return }
        logs = saved
    }
}
