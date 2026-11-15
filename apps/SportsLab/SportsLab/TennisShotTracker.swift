import Foundation

enum TennisShotKind: String, Codable, CaseIterable, Identifiable {
    case forehand = "正手"
    case backhand = "反手"
    case firstServe = "一发"
    case secondServe = "二发"
    case volley = "网前截击"
    var id: String { rawValue }
}

enum TennisCourtZone: String, Codable {
    case deuceServeBox = "一区发球区"
    case adServeBox = "二区发球区"
    case deepBaseline = "底线深区"
    case midCourt = "中场过渡区"
    case outLong = "底线出界"
    case outWide = "边线出界"

    var isInBounds: Bool { self != .outLong && self != .outWide }
}

struct TennisShotRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: TennisShotKind
    let x: Double
    let y: Double
    let zone: TennisCourtZone
}

struct TennisStatsSummary: Equatable {
    let totalShots: Int
    let inBoundsRate: Double
    let firstServeInRate: Double
    let deepBallRate: Double
    let unforcedErrorCount: Int
}

@MainActor
final class TennisShotTracker: ObservableObject {
    @Published private(set) var shots: [TennisShotRecord] = []

    private let defaults: UserDefaults
    private let storageKey = "sports.tennis.shots.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    static func classify(x: Double, y: Double) -> TennisCourtZone {
        if x < 0.1 || x > 0.9 { return .outWide }
        if y < 0.1 { return .outLong }
        if y >= 0.55 { return x < 0.5 ? .adServeBox : .deuceServeBox }
        if y < 0.30 { return .deepBaseline }
        return .midCourt
    }

    func addShot(kind: TennisShotKind, x: Double, y: Double) {
        let cx = max(0.0, min(1.0, x))
        let cy = max(0.0, min(1.0, y))
        shots.insert(TennisShotRecord(id: UUID(), date: Date(), kind: kind, x: cx, y: cy, zone: Self.classify(x: cx, y: cy)), at: 0)
        save()
    }

    func clearAll() {
        shots.removeAll()
        save()
    }

    var summary: TennisStatsSummary { Self.summarize(shots) }

    static func summarize(_ shots: [TennisShotRecord]) -> TennisStatsSummary {
        let total = shots.count
        guard total > 0 else {
            return TennisStatsSummary(totalShots: 0, inBoundsRate: 0, firstServeInRate: 0, deepBallRate: 0, unforcedErrorCount: 0)
        }
        let inBounds = shots.filter { $0.zone.isInBounds }.count
        let firstServes = shots.filter { $0.kind == .firstServe }
        let firstServeIn = firstServes.filter { $0.zone == .deuceServeBox || $0.zone == .adServeBox }.count
        let groundstrokes = shots.filter { $0.kind == .forehand || $0.kind == .backhand }
        let deepBalls = groundstrokes.filter { $0.zone == .deepBaseline }.count
        return TennisStatsSummary(
            totalShots: total,
            inBoundsRate: Double(inBounds) / Double(total),
            firstServeInRate: firstServes.isEmpty ? 0 : Double(firstServeIn) / Double(firstServes.count),
            deepBallRate: groundstrokes.isEmpty ? 0 : Double(deepBalls) / Double(groundstrokes.count),
            unforcedErrorCount: total - inBounds
        )
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shots) { defaults.set(data, forKey: storageKey) }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([TennisShotRecord].self, from: data) else { return }
        shots = saved
    }
}
