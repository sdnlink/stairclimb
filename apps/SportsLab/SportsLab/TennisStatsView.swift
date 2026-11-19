import SwiftUI
import UIKit

@MainActor
struct TennisStatsView: View {
    @ObservedObject var tracker: TennisShotTracker
    @ObservedObject var health: HealthKitService
    @State private var selectedKind: TennisShotKind = .forehand
    @State private var filterKind: TennisShotKind? = nil
    @State private var showHeatmap = true

    // Live Match Scoreboard state
    @State private var mySets = 0
    @State private var oppSets = 0
    @State private var myGames = 0
    @State private var oppGames = 0
    @State private var myPoints = 0
    @State private var oppPoints = 0

    private var displayedShots: [TennisShotRecord] {
        guard let filter = filterKind else { return tracker.shots }
        return tracker.shots.filter { $0.kind == filter }
    }

    var body: some View {
        ZStack {
            AmbientLabBackground(accent: .green)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    liveScoreboardCard
                    shotKindPillBar
                    courtRadarCard
                    telemetryGrid
                    if !tracker.shots.isEmpty {
                        shotKindAnalyticsCard
                        zoneAnalyticsCard
                        recentShotsCard
                    }
                    healthTennisCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("网球落点雷达")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await health.refresh() }
                } label: {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.green)
                }
                .disabled(health.loading)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var liveScoreboardCard: some View {
        VStack(spacing: 10) {
            HStack {
                Label("实时比赛计分板", systemImage: "sportscourt.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("重置比分") {
                    mySets = 0; oppSets = 0; myGames = 0; oppGames = 0; myPoints = 0; oppPoints = 0
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选手")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                    Text("我方 (ME)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.green)
                    Text("对手 (OPP)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                scoreColumn(title: "盘 SET", top: "\(mySets)", bottom: "\(oppSets)", highlight: .white)
                scoreColumn(title: "局 GAME", top: "\(myGames)", bottom: "\(oppGames)", highlight: .cyan)
                scoreColumn(title: "分 PT", top: formattedPoint(my: myPoints, opp: oppPoints), bottom: formattedPoint(my: oppPoints, opp: myPoints), highlight: .green)
            }

            HStack(spacing: 10) {
                Button {
                    awardPoint(toMe: true)
                } label: {
                    Text("+ 我方得分 (Winner/Ace)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing), in: Capsule())
                }
                Button {
                    awardPoint(toMe: false)
                } label: {
                    Text("+ 对手得分")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(14)
        .glassLabCard(accent: .green, cornerRadius: 20)
    }

    private func scoreColumn(title: String, top: String, bottom: String, highlight: Color) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Text(top)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(highlight)
                .frame(minWidth: 34)
            Text(bottom)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 34)
        }
    }

    private func formattedPoint(my: Int, opp: Int) -> String {
        if my >= 3 && opp >= 3 {
            if my == opp { return "40" }
            return my > opp ? "AD" : "40"
        }
        let table = ["0", "15", "30", "40"]
        return table[min(my, 3)]
    }

    private func awardPoint(toMe: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if toMe { myPoints += 1 } else { oppPoints += 1 }
        if myPoints >= 4 && myPoints - oppPoints >= 2 {
            myGames += 1
            myPoints = 0; oppPoints = 0
            if myGames >= 6 && myGames - oppGames >= 2 {
                mySets += 1; myGames = 0; oppGames = 0
            }
        } else if oppPoints >= 4 && oppPoints - myPoints >= 2 {
            oppGames += 1
            myPoints = 0; oppPoints = 0
            if oppGames >= 6 && oppGames - myGames >= 2 {
                oppSets += 1; myGames = 0; oppGames = 0
            }
        }
    }

    private var shotKindPillBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TennisShotKind.allCases) { kind in
                    let active = selectedKind == kind
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            selectedKind = kind
                        }
                    } label: {
                        Text(kind.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(active ? .black : .white.opacity(0.75))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(active ? Color.green : Color.white.opacity(0.08), in: Capsule())
                    }
                }
            }
        }
    }

    private var courtRadarCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("对方半场落点分布")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("点击球场任意位置记录 \(selectedKind.rawValue) 落点")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if tracker.shots.isEmpty {
                    Button {
                        seedDemoRally()
                    } label: {
                        Text("载入示例")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.green, in: Capsule())
                    }
                } else {
                    HStack(spacing: 6) {
                        Button {
                            showHeatmap.toggle()
                        } label: {
                            Text(showHeatmap ? "热区:开" : "热区:关")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.cyan.opacity(0.15), in: Capsule())
                        }
                        Button {
                            tracker.undoLastShot()
                        } label: {
                            Text("撤销")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                        }
                        Button(role: .destructive) {
                            tracker.clearAll()
                        } label: {
                            Text("清空")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }

            TennisCourtCanvas(shots: displayedShots, showHeatmap: showHeatmap) { x, y in
                tracker.addShot(kind: selectedKind, x: x, y: y)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .frame(height: 250)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("落点筛选")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                    Button {
                        filterKind = nil
                    } label: {
                        Text("全部(\(tracker.shots.count))")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(filterKind == nil ? .black : .white.opacity(0.75))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(filterKind == nil ? Color.cyan : Color.white.opacity(0.08), in: Capsule())
                    }
                    ForEach(TennisShotKind.allCases) { kind in
                        let active = filterKind == kind
                        Button {
                            filterKind = active ? nil : kind
                        } label: {
                            Text(kind.rawValue)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(active ? .black : .white.opacity(0.75))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(active ? Color.cyan : Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                Label("界内", systemImage: "circle.fill").foregroundStyle(.green)
                Label("出界 (\(tracker.summary.unforcedErrorCount))", systemImage: "circle.fill").foregroundStyle(.red)
                Spacer()
                if let latest = tracker.shots.first {
                    Text("最近：\(latest.kind.rawValue) · \(latest.zone.rawValue)")
                        .foregroundStyle(.cyan)
                }
            }
            .font(.caption2.weight(.semibold))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.green.opacity(0.28), lineWidth: 1)
                )
        )
    }

    private var telemetryGrid: some View {
        let s = tracker.summary
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            TennisMetricTile(title: "总击球数", value: "\(s.totalShots)", unit: "记", accent: .white)
            TennisMetricTile(title: "界内率", value: String(format: "%.1f", s.inBoundsRate * 100), unit: "%", accent: .green)
            TennisMetricTile(title: "一发进区率", value: String(format: "%.1f", s.firstServeInRate * 100), unit: "%", accent: .cyan)
            TennisMetricTile(title: "底线深球率", value: String(format: "%.1f", s.deepBallRate * 100), unit: "%", accent: .orange)
        }
    }

    private var healthTennisCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apple Health 网球训练")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if let hr = health.snapshot.latestHeartRateBPM {
                    Text("最近心率 \(Int(hr.rounded())) bpm")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.green)
                }
            }

            if health.snapshot.tennisWorkouts.isEmpty {
                Text("暂无网球训练记录（可在首页同步 Apple 健康）")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(health.snapshot.tennisWorkouts.prefix(5)) { w in
                    HStack {
                        Text(w.startDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        let hrText = w.averageHeartRateBPM.map { " · \(Int($0.rounded())) bpm" } ?? ""
                        Text("\(Int(w.durationSeconds / 60)) 分钟\(hrText)")
                            .foregroundStyle(.green)
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var shotKindAnalyticsCard: some View {
        let kinds = TennisShotKind.allCases.compactMap { k -> (kind: TennisShotKind, count: Int, inRate: Double)? in
            let sub = tracker.shots.filter { $0.kind == k }
            guard !sub.isEmpty else { return nil }
            let inCount = sub.filter { $0.zone.isInBounds }.count
            return (k, sub.count, Double(inCount) / Double(sub.count))
        }

        return VStack(alignment: .leading, spacing: 10) {
            Text("各拍型表现拆解")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            ForEach(kinds, id: \.kind.id) { item in
                HStack(spacing: 10) {
                    Text(item.kind.rawValue)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.cyan)
                        .frame(width: 64, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(colors: [.cyan, .green], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(10, geo.size.width * item.inRate))
                        }
                    }
                    .frame(height: 8)
                    Text("\(item.count)拍 · \(Int((item.inRate * 100).rounded()))%界内")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 96, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var zoneAnalyticsCard: some View {
        let grouped = Dictionary(grouping: tracker.shots, by: \.zone)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
        let total = max(1, tracker.shots.count)

        return VStack(alignment: .leading, spacing: 10) {
            Text("落点区域分布")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            ForEach(grouped, id: \.key.rawValue) { zone, count in
                let ratio = Double(count) / Double(total)
                let barColor: Color = zone.isInBounds ? .green : .red
                HStack(spacing: 10) {
                    Text(zone.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 78, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(barColor.opacity(0.85))
                            .frame(width: max(12, geo.size.width * ratio), height: 10)
                    }
                    .frame(height: 10)
                    Text("\(count) (\(Int((ratio * 100).rounded()))%)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(barColor)
                        .frame(width: 68, alignment: .trailing)
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

    private var recentShotsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近击球序列")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            ForEach(tracker.shots.prefix(6)) { shot in
                HStack {
                    Text(shot.kind.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(shot.zone.isInBounds ? Color.green : Color.red, in: Capsule())
                    Text(shot.zone.rawValue)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(shot.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func seedDemoRally() {
        let samples: [(TennisShotKind, Double, Double)] = [
            (.firstServe, 0.66, 0.68),
            (.firstServe, 0.34, 0.72),
            (.firstServe, 0.72, 0.42),
            (.forehand, 0.76, 0.19),
            (.forehand, 0.24, 0.22),
            (.backhand, 0.22, 0.26),
            (.backhand, 0.06, 0.48),
            (.volley, 0.62, 0.46)
        ]
        for (kind, x, y) in samples {
            tracker.addShot(kind: kind, x: x, y: y)
        }
    }
}

private struct TennisMetricTile: View {
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
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassLabCard(accent: accent, cornerRadius: 16)
    }
}

private struct TennisCourtCanvas: View {
    let shots: [TennisShotRecord]
    var showHeatmap: Bool = true
    let onTap: (Double, Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let courtRect = CGRect(x: size.width * 0.1, y: size.height * 0.1, width: size.width * 0.8, height: size.height * 0.86)
                let singlesRect = CGRect(x: size.width * 0.18, y: courtRect.minY, width: size.width * 0.64, height: courtRect.height)
                let deepRect = CGRect(x: singlesRect.minX, y: courtRect.minY, width: singlesRect.width, height: size.height * 0.18)

                context.fill(Path(courtRect), with: .color(Color(red: 0.05, green: 0.22, blue: 0.20).opacity(0.65)))
                context.fill(Path(deepRect), with: .color(Color.orange.opacity(0.11)))
                context.stroke(Path(courtRect), with: .color(.white.opacity(0.8)), lineWidth: 2)
                context.stroke(Path(singlesRect), with: .color(.white.opacity(0.55)), lineWidth: 1.5)

                let serviceY = size.height * 0.55
                var serviceLine = Path()
                serviceLine.move(to: CGPoint(x: singlesRect.minX, y: serviceY))
                serviceLine.addLine(to: CGPoint(x: singlesRect.maxX, y: serviceY))
                serviceLine.move(to: CGPoint(x: size.width * 0.5, y: serviceY))
                serviceLine.addLine(to: CGPoint(x: size.width * 0.5, y: courtRect.maxY))
                // Center baseline mark
                serviceLine.move(to: CGPoint(x: size.width * 0.5, y: courtRect.minY))
                serviceLine.addLine(to: CGPoint(x: size.width * 0.5, y: courtRect.minY + 8))
                context.stroke(serviceLine, with: .color(.white.opacity(0.55)), lineWidth: 1.5)

                // Net band at bottom
                let netRect = CGRect(x: courtRect.minX - 6, y: courtRect.maxY - 2, width: courtRect.width + 12, height: 5)
                context.fill(Path(netRect), with: .color(.white.opacity(0.65)))

                if showHeatmap {
                    for shot in shots.prefix(120) {
                        let pt = CGPoint(x: shot.x * size.width, y: shot.y * size.height)
                        let heatColor: Color = shot.zone.isInBounds ? .green : .orange
                        let radius: CGFloat = 24
                        context.fill(
                            Path(ellipseIn: CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(heatColor.opacity(0.10))
                        )
                    }
                }

                for (idx, shot) in shots.prefix(120).enumerated() {
                    let pt = CGPoint(x: shot.x * size.width, y: shot.y * size.height)
                    let dotColor: Color = shot.zone.isInBounds ? .green : .red
                    let haloSize: CGFloat = idx == 0 ? 18 : 12
                    context.fill(
                        Path(ellipseIn: CGRect(x: pt.x - haloSize / 2, y: pt.y - haloSize / 2, width: haloSize, height: haloSize)),
                        with: .color(dotColor.opacity(idx == 0 ? 0.35 : 0.18))
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)),
                        with: .color(dotColor)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        onTap(Double(value.location.x / max(1, geo.size.width)), Double(value.location.y / max(1, geo.size.height)))
                    }
            )
        }
        .background(Color(red: 0.04, green: 0.06, blue: 0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
