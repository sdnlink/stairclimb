import SwiftUI

@MainActor
struct TennisStatsView: View {
    @ObservedObject var tracker: TennisShotTracker
    @ObservedObject var health: HealthKitService
    @State private var selectedKind: TennisShotKind = .forehand

    var body: some View {
        List {
            Section("Apple 健康状态") {
                Text(health.snapshot.statusMessage).font(.caption)
                if let hr = health.snapshot.latestHeartRateBPM {
                    LabeledContent("最近心率", value: "\(Int(hr.rounded())) bpm")
                }
            }

            Section("点击对方半场记录落点") {
                Picker("击球类型", selection: $selectedKind) {
                    ForEach(TennisShotKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TennisCourtCanvas(shots: tracker.shots) { x, y in
                    tracker.addShot(kind: selectedKind, x: x, y: y)
                }
                .frame(height: 230)
                Text("绿点：界内；红点：出界。上方为对手底线，下方为球网。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("落点统计汇总") {
                let s = tracker.summary
                LabeledContent("总击球数", value: "\(s.totalShots)")
                LabeledContent("界内率", value: String(format: "%.1f%%", s.inBoundsRate * 100))
                LabeledContent("一发进区率", value: String(format: "%.1f%%", s.firstServeInRate * 100))
                LabeledContent("底线深球率", value: String(format: "%.1f%%", s.deepBallRate * 100))
                LabeledContent("出界失误", value: "\(s.unforcedErrorCount)")
                if !tracker.shots.isEmpty {
                    Button("清空本场落点记录", role: .destructive) { tracker.clearAll() }
                }
            }

            if !health.snapshot.tennisWorkouts.isEmpty {
                Section("Apple 健康网球训练记录") {
                    ForEach(health.snapshot.tennisWorkouts.prefix(5)) { w in
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
        }
        .navigationTitle("网球落点统计")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("同步健康") { Task { await health.refresh() } }.disabled(health.loading)
            }
        }
    }
}

private struct TennisCourtCanvas: View {
    let shots: [TennisShotRecord]
    let onTap: (Double, Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let courtRect = CGRect(x: size.width * 0.1, y: size.height * 0.1, width: size.width * 0.8, height: size.height * 0.9)
                context.fill(Path(courtRect), with: .color(Color.teal.opacity(0.18)))
                context.stroke(Path(courtRect), with: .color(.primary), lineWidth: 2)
                let serviceY = size.height * 0.55
                var serviceLine = Path()
                serviceLine.move(to: CGPoint(x: courtRect.minX, y: serviceY))
                serviceLine.addLine(to: CGPoint(x: courtRect.maxX, y: serviceY))
                serviceLine.move(to: CGPoint(x: size.width * 0.5, y: serviceY))
                serviceLine.addLine(to: CGPoint(x: size.width * 0.5, y: courtRect.maxY))
                context.stroke(serviceLine, with: .color(.primary.opacity(0.6)), lineWidth: 1.5)
                for shot in shots.prefix(120) {
                    let pt = CGPoint(x: shot.x * size.width, y: shot.y * size.height)
                    context.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(shot.zone.isInBounds ? .green : .red))
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
