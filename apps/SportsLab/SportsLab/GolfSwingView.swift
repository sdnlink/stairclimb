import Combine
import SwiftUI

struct GolfSwingView: View {
    @ObservedObject var analyzer: GolfSwingAnalyzer
    @ObservedObject var health: HealthKitService

    @State private var selectedClub = "7号铁"
    @State private var backswingMs = 920.0
    @State private var downswingMs = 310.0
    @State private var peakGyro = 1240.0
    @State private var planeDeviation = 2.0
    @State private var replayProgress = 1.0
    @State private var isReplaying = false
    @State private var showSimulatorTuner = false
    @State private var ghostRecord: GolfSwingRecord?

    private let clubs = ["1号木", "3号木", "7号铁", "P杆"]
    private let replayTimer = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.09),
                    Color(red: 0.06, green: 0.09, blue: 0.15),
                    Color(red: 0.03, green: 0.05, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    clubPillBar
                    trajectoryRadarCard
                    if let latest = analyzer.records.first {
                        telemetryHudBar(for: latest)
                        coachingAndSummaryCard(for: latest)
                    }
                    liveCaptureCard
                    simulatorDrawerCard
                    healthGolfCard
                    historySection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("挥杆雷达实验室")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onReceive(replayTimer) { _ in
            guard isReplaying else { return }
            if replayProgress >= 1.0 {
                replayProgress = 0.0
            }
            replayProgress = min(1.0, replayProgress + 0.025)
            if replayProgress >= 1.0 {
                isReplaying = false
            }
        }
    }

    private var clubPillBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(clubs, id: \.self) { club in
                    let active = selectedClub == club
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            selectedClub = club
                        }
                    } label: {
                        Text(club)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(active ? .black : .white.opacity(0.75))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(active ? Color.cyan : Color.white.opacity(0.08))
                            )
                    }
                }
            }
        }
    }

    private var trajectoryRadarCard: some View {
        let activePoints = analyzer.records.first?.points
            ?? GolfSwingAnalyzer.generateTrajectory(planeDeviationDegrees: planeDeviation)

        return VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(analyzer.records.first != nil ? "实测挥杆平面雷达" : "预演挥杆平面雷达")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(analyzer.records.first?.pathTendency ?? "调整下方参数或开启 100Hz 采集")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if analyzer.records.isEmpty {
                    Button {
                        analyzer.recordManual(club: "7号铁", backswingMs: 910, downswingMs: 300, peakAngularVelocityDegPerSec: 1220, planeDeviationDegrees: 1.5)
                        analyzer.recordManual(club: "1号木", backswingMs: 980, downswingMs: 320, peakAngularVelocityDegPerSec: 1460, planeDeviationDegrees: 5.0)
                        replayProgress = 0.0
                        isReplaying = true
                    } label: {
                        Text("载入示例")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                }
                Button {
                    if isReplaying {
                        isReplaying = false
                    } else {
                        if replayProgress >= 0.99 { replayProgress = 0.0 }
                        isReplaying = true
                    }
                } label: {
                    Label(isReplaying ? "暂停" : "回放轨迹", systemImage: isReplaying ? "pause.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.cyan, in: Capsule())
                }
            }

            SwingTrajectoryCanvas(
                points: activePoints,
                ghostPoints: ghostRecord?.points ?? [],
                progress: replayProgress
            )
            .frame(height: 250)

            if let ghost = ghostRecord {
                HStack {
                    Label("残影对比：\(ghost.club) · \(ghost.consistencyScore)分", systemImage: "square.on.square.dashed")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                    Spacer()
                    Button("清除对比") {
                        ghostRecord = nil
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.purple.opacity(0.14), in: Capsule())
            }

            HStack(spacing: 10) {
                Text("帧回放")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Slider(value: $replayProgress, in: 0.05...1.0)
                    .tint(.cyan)
                Text("\(Int((replayProgress * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.cyan)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func telemetryHudBar(for record: GolfSwingRecord) -> some View {
        HStack(spacing: 10) {
            HudGaugeCard(
                title: "杆头速度",
                value: String(format: "%.1f", record.estimatedClubSpeedMph),
                unit: "mph",
                accent: .cyan,
                sublabel: record.club
            )

            HudGaugeCard(
                title: "节奏比例",
                value: String(format: "%.2f", record.tempoRatio),
                unit: ":1",
                accent: abs(record.tempoRatio - 3.0) <= 0.35 ? .mint : .orange,
                sublabel: "标准 3.00:1"
            )

            HudGaugeCard(
                title: "一致性",
                value: "\(record.consistencyScore)",
                unit: "分",
                accent: record.consistencyScore >= 85 ? .green : .orange,
                sublabel: String(format: "偏差 %.1f°", record.planeDeviationDegrees)
            )
        }
    }

    private func coachingAndSummaryCard(for latest: GolfSwingRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
                Text("生物力学动作建议")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }

            Text(GolfSwingAnalyzer.coachingAdvice(tempoRatio: latest.tempoRatio, planeDeviationDegrees: latest.planeDeviationDegrees))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(3)

            if let summary = analyzer.clubSummary(for: selectedClub) {
                Divider().overlay(Color.white.opacity(0.08))
                HStack {
                    Text("\(selectedClub) 均值（\(summary.count) 次）")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text("\(summary.avgSpeedMph) mph · \(String(format: "%.2f", summary.avgTempo)):1 · \(summary.avgScore)分")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.cyan)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cyan.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.cyan.opacity(0.24), lineWidth: 1)
                )
        )
    }

    private var liveCaptureCard: some View {
        HStack(spacing: 14) {
            Button {
                if analyzer.isCapturing {
                    analyzer.stopLiveCapture(club: selectedClub)
                    replayProgress = 0.0
                    isReplaying = true
                } else {
                    analyzer.startLiveCapture(club: selectedClub)
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke((analyzer.isCapturing ? Color.red : Color.mint).opacity(0.35), lineWidth: 4)
                        .frame(width: 58, height: 58)
                    Circle()
                        .fill(analyzer.isCapturing ? Color.red : Color.mint)
                        .frame(width: 46, height: 46)
                    Image(systemName: analyzer.isCapturing ? "stop.fill" : "gyroscope")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.black)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(analyzer.isCapturing ? "100Hz 传感器采集中" : "真机陀螺仪采集")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(analyzer.liveSamplesCount) 帧")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.mint)
                }
                Text(analyzer.liveStatusText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
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

    private var simulatorDrawerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showSimulatorTuner.toggle()
                }
            } label: {
                HStack {
                    Label("参数模拟与轨迹微调", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: showSimulatorTuner ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if showSimulatorTuner {
                VStack(alignment: .leading, spacing: 8) {
                    SliderRow(title: "上杆耗时", valueText: "\(Int(backswingMs)) ms", value: $backswingMs, range: 450...1500, step: 10, tint: .cyan)
                    SliderRow(title: "下杆耗时", valueText: "\(Int(downswingMs)) ms", value: $downswingMs, range: 180...600, step: 10, tint: .orange)
                    SliderRow(title: "峰值角速度", valueText: "\(Int(peakGyro)) deg/s", value: $peakGyro, range: 600...1800, step: 20, tint: .mint)
                    SliderRow(title: "平面偏差", valueText: String(format: "%.1f°", planeDeviation), value: $planeDeviation, range: -12...12, step: 0.5, tint: .purple)

                    Button {
                        analyzer.recordManual(
                            club: selectedClub,
                            backswingMs: Int(backswingMs),
                            downswingMs: Int(downswingMs),
                            peakAngularVelocityDegPerSec: peakGyro,
                            planeDeviationDegrees: planeDeviation
                        )
                        replayProgress = 0.0
                        isReplaying = true
                    } label: {
                        Text("生成挥杆分析并回放")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                LinearGradient(colors: [.cyan, .mint], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .padding(.top, 4)
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

    private var healthGolfCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Health 高尔夫体能")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            if health.snapshot.golfWorkouts.isEmpty {
                Text("暂无高尔夫体能记录（可在首页点击同步体能数据）")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(health.snapshot.golfWorkouts) { item in
                    HStack {
                        Text(item.startDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        let hrText = item.averageHeartRateBPM.map { " · \(Int($0.rounded())) bpm" } ?? ""
                        Text("\(Int(item.durationSeconds / 60)) 分钟\(hrText)")
                            .foregroundStyle(.mint)
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !analyzer.records.isEmpty {
                Text("历史挥杆档案（点图钉可设为残影对比）")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))

                ForEach(analyzer.records) { record in
                    let isGhost = ghostRecord?.id == record.id
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(record.club) · \(record.consistencyScore)分")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("节奏 \(String(format: "%.2f", record.tempoRatio)):1 · \(record.pathTendency)")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Text("\(record.estimatedClubSpeedMph) mph")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.cyan)
                        Button {
                            ghostRecord = isGhost ? nil : record
                        } label: {
                            Image(systemName: isGhost ? "pin.fill" : "pin")
                                .font(.caption)
                                .foregroundStyle(isGhost ? .purple : .white.opacity(0.45))
                                .padding(.leading, 8)
                        }
                        Button(role: .destructive) {
                            if isGhost { ghostRecord = nil }
                            analyzer.deleteRecord(record)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.leading, 8)
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

private struct HudGaugeCard: View {
    let title: String
    let value: String
    let unit: String
    let accent: Color
    let sublabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text(sublabel)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(accent.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

private struct SliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
            }
            Slider(value: $value, in: range, step: step)
                .tint(tint)
        }
    }
}

private struct SwingTrajectoryCanvas: View {
    let points: [SwingPoint]
    var ghostPoints: [SwingPoint] = []
    let progress: Double

    private var referencePoints: [SwingPoint] {
        GolfSwingAnalyzer.generateTrajectory(planeDeviationDegrees: 0.0)
    }

    private var visibleCount: Int {
        guard !points.isEmpty else { return 0 }
        return max(2, min(points.count, Int((Double(points.count) * progress).rounded())))
    }

    private var activePoint: SwingPoint? {
        guard visibleCount > 0, visibleCount <= points.count else { return points.last }
        return points[visibleCount - 1]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.04, green: 0.06, blue: 0.11))

            Canvas { context, size in
                drawRadarGrid(in: size, context: &context)

                drawPath(
                    for: referencePoints,
                    in: size,
                    context: &context,
                    color: .white.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )

                if !ghostPoints.isEmpty {
                    drawPath(
                        for: ghostPoints,
                        in: size,
                        context: &context,
                        color: Color.purple.opacity(0.65),
                        style: StrokeStyle(lineWidth: 2.5, dash: [4, 3])
                    )
                }

                let sliced = Array(points.prefix(visibleCount))
                let backswing = sliced.filter { $0.phase == "backswing" }
                let downswing = sliced.filter { $0.phase == "downswing" }

                drawPath(
                    for: backswing,
                    in: size,
                    context: &context,
                    color: Color.cyan.opacity(0.35),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                )
                drawPath(
                    for: backswing,
                    in: size,
                    context: &context,
                    color: .cyan,
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                )

                let connectedDownswing = (backswing.last.map { [$0] } ?? []) + downswing
                drawPath(
                    for: connectedDownswing,
                    in: size,
                    context: &context,
                    color: Color.orange.opacity(0.35),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                )
                drawPath(
                    for: connectedDownswing,
                    in: size,
                    context: &context,
                    color: .orange,
                    style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round)
                )

                if let head = activePoint {
                    let center = CGPoint(x: head.x * size.width, y: head.y * size.height)
                    let halo = CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
                    let core = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
                    let headColor: Color = head.phase == "backswing" ? .cyan : .orange
                    context.fill(Path(ellipseIn: halo), with: .color(headColor.opacity(0.35)))
                    context.fill(Path(ellipseIn: core), with: .color(.white))
                }
            }

            HStack(spacing: 12) {
                Label("标准3:1平面", systemImage: "line.diagonal")
                    .foregroundStyle(.white.opacity(0.55))
                Label("上杆", systemImage: "circle.fill")
                    .foregroundStyle(.cyan)
                Label("下杆", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                if let phase = activePoint?.phase {
                    Text(phase == "backswing" ? "上杆阶段" : "下杆击球")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (phase == "backswing" ? Color.cyan : Color.orange).opacity(0.22),
                            in: Capsule()
                        )
                        .foregroundStyle(phase == "backswing" ? .cyan : .orange)
                }
            }
            .font(.caption2.weight(.semibold))
            .padding(10)
        }
    }

    private func drawRadarGrid(in size: CGSize, context: inout GraphicsContext) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.55)
        for radius in stride(from: 42.0, through: 130.0, by: 42.0) {
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.06)), lineWidth: 1)
        }
        var cross = Path()
        cross.move(to: CGPoint(x: 0, y: center.y))
        cross.addLine(to: CGPoint(x: size.width, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: 0))
        cross.addLine(to: CGPoint(x: center.x, y: size.height))
        context.stroke(cross, with: .color(.white.opacity(0.06)), lineWidth: 1)
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
}
