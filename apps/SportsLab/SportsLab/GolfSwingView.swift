import SwiftUI

struct GolfSwingView: View {
    @ObservedObject var analyzer: GolfSwingAnalyzer
    @ObservedObject var health: HealthKitService

    @State private var selectedClub = "7号铁"
    @State private var backswingMs = 920.0
    @State private var downswingMs = 310.0
    @State private var peakGyro = 1240.0
    @State private var planeDeviation = 2.0

    private let clubs = ["1号木", "3号木", "7号铁", "P杆"]

    var body: some View {
        NavigationStack {
            List {
                if let latest = analyzer.records.first {
                    Section("最新挥杆轨迹（含标准平面参考线）") {
                        SwingTrajectoryCanvas(points: latest.points)
                            .frame(height: 230)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))

                        HStack {
                            MetricBadge(title: "杆头速度", value: "\(latest.estimatedClubSpeedMph) mph")
                            MetricBadge(title: "节奏比", value: "\(String(format: "%.2f", latest.tempoRatio)):1")
                            MetricBadge(title: "一致性", value: "\(latest.consistencyScore)分")
                        }
                        Text("轨迹倾向：\(latest.pathTendency) · 平面偏差 \(String(format: "%.1f°", latest.planeDeviationDegrees))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("动作建议：\(GolfSwingAnalyzer.coachingAdvice(tempoRatio: latest.tempoRatio, planeDeviationDegrees: latest.planeDeviationDegrees))")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }

                if let summary = analyzer.clubSummary(for: selectedClub) {
                    Section("\(selectedClub) 历史均值（\(summary.count) 次）") {
                        HStack {
                            MetricBadge(title: "平均杆速", value: "\(summary.avgSpeedMph) mph")
                            MetricBadge(title: "平均节奏", value: "\(String(format: "%.2f", summary.avgTempo)):1")
                            MetricBadge(title: "平均评分", value: "\(summary.avgScore)分")
                        }
                    }
                }

                Section("挥杆采集 / 参数模拟") {
                    Picker("球杆", selection: $selectedClub) {
                        ForEach(clubs, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Button(analyzer.isCapturing ? "停止采集" : "开始真机采集") {
                            if analyzer.isCapturing {
                                analyzer.stopLiveCapture(club: selectedClub)
                            } else {
                                analyzer.startLiveCapture(club: selectedClub)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(analyzer.isCapturing ? .red : .green)

                        Spacer()
                        Text("样本: \(analyzer.liveSamplesCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(analyzer.liveStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading) {
                        Text("上杆耗时: \(Int(backswingMs)) ms")
                        Slider(value: $backswingMs, in: 450...1500, step: 10)
                        Text("下杆耗时: \(Int(downswingMs)) ms")
                        Slider(value: $downswingMs, in: 180...600, step: 10)
                        Text("峰值角速度: \(Int(peakGyro)) deg/s")
                        Slider(value: $peakGyro, in: 600...1800, step: 20)
                        Text("平面偏差: \(String(format: "%.1f°", planeDeviation))")
                        Slider(value: $planeDeviation, in: -12...12, step: 0.5)
                    }

                    Button("生成挥杆分析") {
                        analyzer.recordManual(
                            club: selectedClub,
                            backswingMs: Int(backswingMs),
                            downswingMs: Int(downswingMs),
                            peakAngularVelocityDegPerSec: peakGyro,
                            planeDeviationDegrees: planeDeviation
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section("Apple Health 高尔夫记录") {
                    if health.golfWorkouts.isEmpty {
                        Text("暂无高尔夫体能训练记录（可在总览页开启 HealthKit 授权）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(health.golfWorkouts) { item in
                            HStack {
                                Text(item.startDate.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                Text("\(Int(item.durationMinutes)) 分钟 · \(Int(item.activeEnergyKcal)) kcal")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }

                Section("历史挥杆记录") {
                    ForEach(analyzer.records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(record.club) · \(record.consistencyScore)分")
                                    .font(.headline)
                                Spacer()
                                Text("\(record.estimatedClubSpeedMph) mph")
                                    .foregroundStyle(.blue)
                            }
                            Text("节奏 \(String(format: "%.2f", record.tempoRatio)):1 · \(record.pathTendency)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            analyzer.deleteRecord(analyzer.records[idx])
                        }
                    }
                }
            }
            .navigationTitle("高尔夫挥杆轨迹")
        }
    }
}

private struct MetricBadge: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SwingTrajectoryCanvas: View {
    let points: [SwingPoint]

    private var referencePoints: [SwingPoint] {
        GolfSwingAnalyzer.generateTrajectory(planeDeviationDegrees: 0.0)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))

            Canvas { context, size in
                drawPath(
                    for: referencePoints,
                    in: size,
                    context: &context,
                    color: .gray.opacity(0.45),
                    style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                )

                let backswing = points.filter { $0.phase == "backswing" }
                let downswing = points.filter { $0.phase == "downswing" }

                drawPath(
                    for: backswing,
                    in: size,
                    context: &context,
                    color: .blue,
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                )

                let connectedDownswing = (backswing.last.map { [$0] } ?? []) + downswing
                drawPath(
                    for: connectedDownswing,
                    in: size,
                    context: &context,
                    color: .orange,
                    style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round)
                )

                if let top = backswing.last {
                    drawMarker(at: top, in: size, context: &context, color: .blue)
                }
                if let impact = downswing.last {
                    drawMarker(at: impact, in: size, context: &context, color: .orange)
                }
            }

            HStack(spacing: 12) {
                Label("标准平面", systemImage: "line.diagonal")
                    .foregroundStyle(.gray)
                Label("上杆", systemImage: "circle.fill")
                    .foregroundStyle(.blue)
                Label("下杆", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption2)
            .padding(8)
        }
    }

    private func drawPath(
        for segment: [SwingPoint],
        in size: CGSize,
        context: inout GraphicsContext,
        color: Color,
        style: StrokeStyle
    ) {
        guard segment.count >= 2 else { return }
        var path = Path()
        for (idx, pt) in segment.enumerated() {
            let p = CGPoint(x: pt.x * size.width, y: pt.y * size.height)
            if idx == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        context.stroke(path, with: .color(color), style: style)
    }

    private func drawMarker(
        at point: SwingPoint,
        in size: CGSize,
        context: inout GraphicsContext,
        color: Color
    ) {
        let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
        let rect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }
}
