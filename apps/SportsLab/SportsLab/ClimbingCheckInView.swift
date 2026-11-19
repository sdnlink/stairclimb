import Combine
import SwiftUI
import UIKit

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
    @State private var showCheckInForm = true

    // Hangboard / Rest Interval Timer
    @State private var timerTotalSeconds = 150
    @State private var timerRemainingSeconds = 150
    @State private var isTimerRunning = false
    private let restTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var availableGrades: [String] {
        style == .bouldering ? ClimbingLogStore.boulderingGrades : ClimbingLogStore.leadGrades
    }

    var body: some View {
        ZStack {
            AmbientLabBackground(accent: .purple)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    heroSummaryCard
                    climbingTimerCard
                    activeProjectsCard
                    if !store.entries.isEmpty {
                        gradeBreakdownCard
                        gymStatsCard
                    }
                    checkInFormCard
                    healthClimbingCard
                    routeLogSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("攀岩路线档案")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await health.refresh() }
                } label: {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.purple)
                }
                .disabled(health.loading)
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(restTimer) { _ in
            guard isTimerRunning else { return }
            if timerRemainingSeconds > 0 {
                timerRemainingSeconds -= 1
                if timerRemainingSeconds == 0 {
                    isTimerRunning = false
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            }
        }
    }

    private var climbingTimerCard: some View {
        let presets: [(label: String, sec: Int)] = [
            ("指力板 7s", 7),
            ("组间歇 2:30", 150),
            ("先锋歇 4:00", 240)
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("指力板 / 组间休息倒计时", systemImage: "timer")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%02d:%02d", timerRemainingSeconds / 60, timerRemainingSeconds % 60))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isTimerRunning ? .mint : .purple)
            }

            HStack(spacing: 8) {
                ForEach(presets, id: \.label) { p in
                    let active = timerTotalSeconds == p.sec
                    Button {
                        isTimerRunning = false
                        timerTotalSeconds = p.sec
                        timerRemainingSeconds = p.sec
                    } label: {
                        Text(p.label)
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(active ? .black : .white.opacity(0.75))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(active ? Color.purple : Color.white.opacity(0.08), in: Capsule())
                    }
                }
                Spacer()
                Button {
                    if timerRemainingSeconds == 0 { timerRemainingSeconds = timerTotalSeconds }
                    isTimerRunning.toggle()
                } label: {
                    Image(systemName: isTimerRunning ? "pause.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(isTimerRunning ? Color.orange : Color.mint, in: Capsule())
                }
            }
        }
        .padding(14)
        .glassLabCard(accent: .purple, cornerRadius: 18)
    }

    private var activeProjectsCard: some View {
        let projects = store.entries.filter { !$0.outcome.isCompleted }
        return Group {
            if !projects.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("正在攻坚路线 (Projects)", systemImage: "flame.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("\(projects.count) 条待红点")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    ForEach(projects) { proj in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(proj.grade) · \(proj.routeName)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                Text(proj.gymOrCrag)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer()
                            Button {
                                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    store.markRedpoint(proj.id)
                                }
                            } label: {
                                Text("红点完攀 ✓")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.mint, in: Capsule())
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(14)
                .glassLabCard(accent: .orange, cornerRadius: 18)
            }
        }
    }

    private var heroSummaryCard: some View {
        let s = store.summary
        let rate = s.completionRate
        return HStack(spacing: 16) {
            ZStack {
                DialTickRing(tickCount: 24, radius: 49, tickLength: 3.5)
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 9)
                    .frame(width: 86, height: 86)
                Circle()
                    .trim(from: 0, to: rate)
                    .stroke(
                        AngularGradient(colors: [.purple, .pink, .cyan, .purple], center: .center),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 86, height: 86)
                    .shadow(color: .purple.opacity(0.45), radius: 6)
                VStack(spacing: 1) {
                    Text("\(Int((rate * 100).rounded()))%")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("完攀率")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    GradeBadge(title: "最高抱石", value: s.highestBouldering ?? "--", accent: .purple)
                    GradeBadge(title: "最高难度", value: s.highestLead ?? "--", accent: .cyan)
                }
                HStack {
                    Text("累计打卡 \(s.totalCheckIns) 条 · 完攀 \(s.completedCount) 条")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                    Spacer()
                    if store.entries.isEmpty {
                        Button("载入示例") {
                            seedDemoRoutes()
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.purple, in: Capsule())
                    }
                }
            }
        }
        .padding(16)
        .background(
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.20), Color.white.opacity(0.045)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "figure.climbing")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(Color.purple.opacity(0.08))
                    .offset(x: -8, y: -4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.45), Color.white.opacity(0.12), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        )
    }

    private var gradeBreakdownCard: some View {
        let counts = Dictionary(grouping: store.entries, by: \.grade)
            .mapValues(\.count)
            .sorted { $0.key > $1.key }
        let maxCount = max(1, counts.map(\.value).max() ?? 1)
        let flashes = store.entries.filter { $0.outcome == .flash }.count
        let redpoints = store.entries.filter { $0.outcome == .redpoint }.count
        let attempts = store.entries.filter { $0.outcome == .attempt }.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("难度金字塔与完攀结构", systemImage: "pyramid.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Flash \(flashes) · 红点 \(redpoints) · 尝试 \(attempts)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.cyan)
            }

            ForEach(counts, id: \.key) { item in
                HStack(spacing: 10) {
                    Text(item.key)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.purple)
                        .frame(width: 48, alignment: .leading)
                    GeometryReader { geo in
                        let width = max(24, geo.size.width * CGFloat(item.value) / CGFloat(maxCount))
                        HStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing))
                                .frame(width: width, height: 12)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: 12)
                    Text("\(item.value)条")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 34, alignment: .trailing)
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

    private var gymStatsCard: some View {
        let grouped = Dictionary(grouping: store.entries, by: \.gymOrCrag)
            .map { gym, items -> (gym: String, total: Int, sends: Int) in
                (gym, items.count, items.filter { $0.outcome.isCompleted }.count)
            }
            .sorted { $0.total > $1.total }

        return VStack(alignment: .leading, spacing: 10) {
            Label("常去岩馆 / 岩场表现", systemImage: "mappin.and.ellipse")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            ForEach(grouped, id: \.gym) { item in
                let rate = Int((Double(item.sends) / Double(max(1, item.total)) * 100).rounded())
                HStack {
                    Text(item.gym)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("完攀 \(item.sends)/\(item.total) 条 · \(rate)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.mint)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var checkInFormCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCheckInForm.toggle()
                }
            } label: {
                HStack {
                    Label("新增路线打卡", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: showCheckInForm ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if showCheckInForm {
                VStack(spacing: 10) {
                    TextField("岩馆或野外岩场名称", text: $gymOrCrag)
                        .padding(10)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    TextField("路线名称 / 颜色线编号", text: $routeName)
                        .padding(10)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 8) {
                        ForEach(ClimbingStyle.allCases) { s in
                            let active = style == s
                            Button {
                                style = s
                                grade = s == .bouldering ? "V3" : "5.10a"
                            } label: {
                                Text(s == .bouldering ? "抱石 (V)" : "难度 (YDS)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(active ? .black : .white.opacity(0.75))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(active ? Color.purple : Color.white.opacity(0.07), in: Capsule())
                            }
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(availableGrades, id: \.self) { g in
                                let active = grade == g
                                Button {
                                    grade = g
                                } label: {
                                    Text(g)
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(active ? .black : .white.opacity(0.75))
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(active ? Color.cyan : Color.white.opacity(0.07), in: Capsule())
                                }
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(ClimbingOutcome.allCases) { o in
                            let active = outcome == o
                            Button {
                                outcome = o
                            } label: {
                                Text(o == .flash ? "Flash" : (o == .redpoint ? "Redpoint" : "尝试"))
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(active ? .black : .white.opacity(0.75))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(active ? Color.mint : Color.white.opacity(0.07), in: Capsule())
                            }
                        }
                    }

                    TextField("难点 / Beta 备注（可选）", text: $notes)
                        .padding(10)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

                    Button {
                        store.checkIn(
                            gymOrCrag: gymOrCrag,
                            routeName: routeName,
                            style: style,
                            grade: grade,
                            outcome: outcome,
                            notes: notes
                        )
                        routeName = ""
                        notes = ""
                    } label: {
                        Text("打卡保存")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .disabled(
                        gymOrCrag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                .font(.caption)
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

    private var healthClimbingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apple Health 攀岩体能")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if let hr = health.snapshot.latestHeartRateBPM {
                    Text("最近心率 \(Int(hr.rounded())) bpm")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.purple)
                }
            }

            if health.snapshot.climbingWorkouts.isEmpty {
                Text("暂无攀岩体能记录（可在首页同步 Apple 健康）")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(health.snapshot.climbingWorkouts.prefix(5)) { w in
                    HStack {
                        Text(w.startDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        let hrText = w.averageHeartRateBPM.map { " · \(Int($0.rounded())) bpm" } ?? ""
                        Text("\(Int(w.durationSeconds / 60)) 分钟\(hrText)")
                            .foregroundStyle(.purple)
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var routeLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.entries.isEmpty {
                Text("近期路线档案")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))

                ForEach(store.entries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(entry.grade)
                                    .font(.caption.monospacedDigit().weight(.bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.purple, in: Capsule())
                                Text(entry.routeName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            Text("\(entry.gymOrCrag) · \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                            if !entry.notes.isEmpty {
                                Text(entry.notes)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(entry.outcome.isCompleted ? "完攀" : "尝试")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(entry.outcome.isCompleted ? .mint : .orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background((entry.outcome.isCompleted ? Color.mint : Color.orange).opacity(0.16), in: Capsule())
                            Button(role: .destructive) {
                                store.remove(entry.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func seedDemoRoutes() {
        store.checkIn(gymOrCrag: "香蕉攀岩", routeName: "蓝线动态起跳 #3", style: .bouldering, grade: "V4", outcome: .flash, notes: "左脚高踩后直接甩右点")
        store.checkIn(gymOrCrag: "香蕉攀岩", routeName: "紫线屋檐 #7", style: .bouldering, grade: "V5", outcome: .redpoint, notes: "跟脚挂稳再换手")
        store.checkIn(gymOrCrag: "岩时攀岩", routeName: "白线平衡壁 #2", style: .bouldering, grade: "V6", outcome: .attempt, notes: "最后一点重心略偏左")
    }
}

private struct GradeBadge: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
