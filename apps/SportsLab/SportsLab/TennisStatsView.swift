import SwiftUI

@MainActor
struct TennisStatsView: View {
    @ObservedObject var tracker: TennisShotTracker
    @ObservedObject var health: HealthKitService
    @State private var selectedKind: TennisShotKind = .forehand

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.09),
                    Color(red: 0.05, green: 0.10, blue: 0.13),
                    Color(red: 0.03, green: 0.05, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    shotKindPillBar
                    courtRadarCard
                    telemetryGrid
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
                    Button(role: .destructive) {
                        tracker.clearAll()
                    } label: {
                        Text("清空")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.15), in: Capsule())
                    }
                }
            }

            TennisCourtCanvas(shots: tracker.shots) { x, y in
                tracker.addShot(kind: selectedKind, x: x, y: y)
            }
            .frame(height: 250)

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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(accent.opacity(0.24), lineWidth: 1)
                )
        )
    }
}

private struct TennisCourtCanvas: View {
    let shots: [TennisShotRecord]
    let onTap: (Double, Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let courtRect = CGRect(x: size.width * 0.1, y: size.height * 0.1, width: size.width * 0.8, height: size.height * 0.9)
                let deepRect = CGRect(x: courtRect.minX, y: courtRect.minY, width: courtRect.width, height: size.height * 0.20)
                context.fill(Path(courtRect), with: .color(Color.teal.opacity(0.16)))
                context.fill(Path(deepRect), with: .color(Color.orange.opacity(0.10)))
                context.stroke(Path(courtRect), with: .color(.white.opacity(0.75)), lineWidth: 2)

                let serviceY = size.height * 0.55
                var serviceLine = Path()
                serviceLine.move(to: CGPoint(x: courtRect.minX, y: serviceY))
                serviceLine.addLine(to: CGPoint(x: courtRect.maxX, y: serviceY))
                serviceLine.move(to: CGPoint(x: size.width * 0.5, y: serviceY))
                serviceLine.addLine(to: CGPoint(x: size.width * 0.5, y: courtRect.maxY))
                context.stroke(serviceLine, with: .color(.white.opacity(0.45)), lineWidth: 1.5)

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
