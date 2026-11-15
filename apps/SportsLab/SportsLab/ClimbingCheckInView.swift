import SwiftUI

@MainActor
struct ClimbingCheckInView: View {
    @ObservedObject var store: ClimbingLogStore
    @ObservedObject var health: HealthKitService

    @State private var gymOrCrag = ""
    @State private var routeName = ""
    @State private var style: ClimbingStyle = .bouldering
    @State private var grade = "V3"
    @State private var outcome: ClimbingOutcome = .redpoint
    @State private var notes = ""

    private var availableGrades: [String] {
        style == .bouldering ? ClimbingLogStore.boulderingGrades : ClimbingLogStore.leadGrades
    }

    var body: some View {
        List {
            Section("Apple 健康状态") {
                Text(health.snapshot.statusMessage).font(.caption)
                if let hr = health.snapshot.latestHeartRateBPM {
                    LabeledContent("最近心率", value: "\(Int(hr.rounded())) bpm")
                }
            }

            Section("完攀概览") {
                let s = store.summary
                LabeledContent("累计打卡路线", value: "\(s.totalCheckIns) 条")
                LabeledContent("完攀率", value: String(format: "%.1f%%", s.completionRate * 100))
                if let b = s.highestBouldering { LabeledContent("最高抱石完攀", value: b) }
                if let l = s.highestLead { LabeledContent("最高难度完攀", value: l) }
            }

            Section("新增路线打卡") {
                TextField("岩馆或野外岩场名称", text: $gymOrCrag)
                TextField("路线名称 / 颜色线编号", text: $routeName)
                Picker("攀爬类型", selection: $style) {
                    ForEach(ClimbingStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: style) { _, newValue in
                    grade = newValue == .bouldering ? "V3" : "5.10a"
                }
                Picker("难度等级", selection: $grade) {
                    ForEach(availableGrades, id: \.self) { Text($0) }
                }
                Picker("完成状态", selection: $outcome) {
                    ForEach(ClimbingOutcome.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("难点/动作备注（可选）", text: $notes)
                Button("打卡保存") {
                    store.checkIn(gymOrCrag: gymOrCrag, routeName: routeName, style: style, grade: grade, outcome: outcome, notes: notes)
                    routeName = ""
                    notes = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(gymOrCrag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !health.snapshot.climbingWorkouts.isEmpty {
                Section("Apple 健康攀岩训练记录") {
                    ForEach(health.snapshot.climbingWorkouts.prefix(5)) { w in
                        HStack {
                            Text(w.startDate.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text("\(Int(w.durationSeconds / 60)) 分钟")
                            if let hr = w.averageHeartRateBPM {
                                Text("· \(Int(hr)) bpm").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
            }

            if !store.entries.isEmpty {
                Section("路线打卡记录") {
                    ForEach(store.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(entry.grade) · \(entry.routeName)").font(.subheadline.bold())
                                Spacer()
                                Text(entry.outcome.isCompleted ? "完攀" : "尝试")
                                    .font(.caption)
                                    .foregroundStyle(entry.outcome.isCompleted ? .green : .orange)
                            }
                            Text("\(entry.gymOrCrag) · \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                            if !entry.notes.isEmpty { Text(entry.notes).font(.caption) }
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets { store.remove(store.entries[idx].id) }
                    }
                }
            }
        }
        .navigationTitle("攀岩路线打卡")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("同步健康") { Task { await health.refresh() } }.disabled(health.loading)
            }
        }
    }
}
