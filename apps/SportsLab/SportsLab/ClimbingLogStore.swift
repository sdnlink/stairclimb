import Foundation

enum ClimbingStyle: String, Codable, CaseIterable, Identifiable {
    case bouldering = "抱石 (V难度)"
    case lead = "难度/先锋 (YDS)"
    var id: String { rawValue }
}

enum ClimbingOutcome: String, Codable, CaseIterable, Identifiable {
    case flash = "Flash (首攀完攀)"
    case redpoint = "Redpoint (红点完攀)"
    case attempt = "尝试未完攀"
    var id: String { rawValue }
    var isCompleted: Bool { self == .flash || self == .redpoint }
}

struct ClimbingRouteCheckIn: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let gymOrCrag: String
    let routeName: String
    let style: ClimbingStyle
    let grade: String
    let outcome: ClimbingOutcome
    let notes: String
}

struct ClimbingSummary: Equatable {
    let totalCheckIns: Int
    let completedCount: Int
    let completionRate: Double
    let highestBouldering: String?
    let highestLead: String?
}

@MainActor
final class ClimbingLogStore: ObservableObject {
    @Published private(set) var entries: [ClimbingRouteCheckIn] = []

    static let boulderingGrades = ["V0", "V1", "V2", "V3", "V4", "V5", "V6", "V7", "V8", "V9", "V10"]
    static let leadGrades = ["5.8", "5.9", "5.10a", "5.10c", "5.11a", "5.11c", "5.12a", "5.12c", "5.13a", "5.14a"]

    private let defaults: UserDefaults
    private let storageKey = "sports.climbing.checkins.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func checkIn(gymOrCrag: String, routeName: String, style: ClimbingStyle, grade: String, outcome: ClimbingOutcome, notes: String) {
        let g = gymOrCrag.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = routeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty, !r.isEmpty else { return }
        entries.insert(ClimbingRouteCheckIn(id: UUID(), date: Date(), gymOrCrag: g, routeName: r, style: style, grade: grade, outcome: outcome, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    var summary: ClimbingSummary { Self.summarize(entries) }

    static func summarize(_ entries: [ClimbingRouteCheckIn]) -> ClimbingSummary {
        let completed = entries.filter { $0.outcome.isCompleted }
        let highestB = completed.filter { $0.style == .bouldering }.max { (boulderingGrades.firstIndex(of: $0.grade) ?? -1) < (boulderingGrades.firstIndex(of: $1.grade) ?? -1) }?.grade
        let highestL = completed.filter { $0.style == .lead }.max { (leadGrades.firstIndex(of: $0.grade) ?? -1) < (leadGrades.firstIndex(of: $1.grade) ?? -1) }?.grade
        return ClimbingSummary(
            totalCheckIns: entries.count,
            completedCount: completed.count,
            completionRate: entries.isEmpty ? 0 : Double(completed.count) / Double(entries.count),
            highestBouldering: highestB,
            highestLead: highestL
        )
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: storageKey) }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([ClimbingRouteCheckIn].self, from: data) else { return }
        entries = saved
    }
}
