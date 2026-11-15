import SwiftUI

private enum Palette {
    static let ink = Color(red: 0.10, green: 0.19, blue: 0.24)
    static let jade = Color(red: 0.05, green: 0.42, blue: 0.36)
    static let paper = Color(red: 0.95, green: 0.96, blue: 0.93)
}

@MainActor
struct ProgressViewScreen: View {
    @ObservedObject var model: LocalAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingIdentity = false
    private let datePulse = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var busy: Bool { model.phase == .loading || model.phase == .requesting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    StaircaseView(progress: model.snapshot?.progress)
                    metrics
                    healthStatus
                    privacyNote
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.paper)
            .foregroundStyle(Palette.ink)
            .navigationTitle("爬楼梯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editingIdentity = true } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("本机身份与昵称")
                }
            }
            .refreshable { await model.activate() }
        }
        .tint(Palette.jade)
        .preferredColorScheme(.light)
        .sheet(isPresented: $editingIdentity) { IdentitySheet(model: model) }
        .task { await model.activate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.activate() } }
            else { model.markCached() }
        }
        .onReceive(datePulse) { _ in
            guard scenePhase == .active else { return }
            if model.updateDayIfNeeded() { Task { await model.activate() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("本机健康进度", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.jade)
                Spacer()
                Text("100 步 / 层").font(.caption.monospacedDigit())
            }
            Text(model.identity.map { "\($0.nickname)，一步一步向上" } ?? "把每一步，变成向上的一层")
                .font(.title2.bold())
            Text("\(model.day.date) · 上海时间 Asia/Shanghai")
                .font(.caption).foregroundStyle(.secondary)
            if model.identity == nil {
                Button("创建本机身份与昵称") { editingIdentity = true }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var metrics: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今日步数").font(.subheadline).foregroundStyle(.secondary)
                    Text(model.snapshot.map { $0.progress.steps.formatted() } ?? "—")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("当前虚拟楼层").font(.subheadline).foregroundStyle(.secondary)
                    Text(model.snapshot.map { "\($0.progress.floor) 层" } ?? "— 层")
                        .font(.title2.bold()).monospacedDigit()
                }
            }
            Divider()
            HStack {
                Image(systemName: "arrow.up.right")
                Text(model.snapshot.map { "再走 \($0.progress.remainingSteps) 步，到达下一层" } ?? "读取今日步数后，开始向上")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }

    private var healthStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(statusTitle, systemImage: statusSymbol).font(.headline)
            Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
            if let snapshot = model.snapshot {
                Text("上次成功读取 · 上海 \(ShanghaiDay.timeLabel(for: snapshot.readAt))")
                    .font(.caption).foregroundStyle(.secondary)
                if model.snapshotIsStale {
                    Text("本机缓存，尚未重新读取成功；当前步数可能已变化。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if model.phase != .unavailable {
                HStack {
                    Button {
                        Task {
                            if !model.hasRequestedHealthAccess { await model.requestHealthAccess() }
                            else { await model.refresh() }
                        }
                    } label: {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "正在更新" : !model.hasRequestedHealthAccess ? "连接 Apple 健康" : "重新读取今日步数")
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    if model.phase != .needsRequest && !busy {
                        Button("健康访问") { Task { await model.requestHealthAccess() } }
                            .font(.caption)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        switch model.phase {
        case .needsRequest: "从今天的步数开始"
        case .requesting: "正在请求健康访问"
        case .loading: "正在读取今日步数"
        case .data: "今日进度已更新"
        case .noReadableData: "暂无可读步数"
        case .unavailable: "此设备无法使用健康数据"
        case .failed: "本次更新未完成"
        }
    }

    private var statusDetail: String {
        switch model.phase {
        case .needsRequest: "只读取上海当日步数汇总。你可自行决定健康访问权限；本机查看无需公开共享。"
        case .requesting: "请在系统健康访问页面选择。完成流程不代表已授予读取权限。"
        case .loading: "按上海00:00至次日00:00重新查询；过期的昨日结果不会用于今天。"
        case .data: "这里显示本机今日进度，下拉可刷新。公开共享和服务器同步状态请查看“今日楼层榜”。"
        case .noReadableData: "当前可读汇总为空，暂显示0步。可能尚无记录或未开放读取，App无法区分。可在系统设置的健康权限中检查。"
        case .unavailable: "请在支持 Apple 健康的 iPhone 上使用。这里不会生成演示步数。"
        case .failed: model.readingError ?? "读取未完成，请稍后重试。"
        }
    }

    private var statusSymbol: String {
        switch model.phase {
        case .failed: "exclamationmark.triangle"
        case .unavailable: "heart.slash"
        case .data: "checkmark.circle"
        default: "heart.text.square"
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("走的是步数，登的是虚拟楼层").font(.subheadline.bold())
            Text("每100步兑换1层，是步数游戏换算，不是健康App记录的实际已爬楼层。每日上海00:00重新统计，历史健康数据不会被清除。不采集真实地理位置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct StaircaseView: View {
    let progress: StepProgress?
    private let visibleSteps = 5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let base = max(0, (progress?.floor ?? 0) - 2)
            let current = (progress?.floor ?? 0) - base
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 28)
                    .fill(LinearGradient(colors: [Palette.jade, Color(red: 0.04, green: 0.27, blue: 0.29)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 5) {
                    Text("今天的高度").font(.caption.weight(.medium)).opacity(0.8)
                    Text(progress.map { "\($0.floor)F" } ?? "— F")
                        .font(.system(size: 50, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white).padding(24).frame(maxHeight: .infinity, alignment: .topLeading)

                ForEach(0..<visibleSteps, id: \.self) { index in
                    let stepWidth = (width - 40) / CGFloat(visibleSteps)
                    let height = CGFloat(35 + index * 28)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white.opacity(index == current ? 0.95 : 0.15 + Double(index) * 0.03))
                        .frame(width: stepWidth + 2, height: height)
                        .overlay(alignment: .top) {
                            Text("\(base + index)F")
                                .font(.caption2.bold()).monospacedDigit()
                                .foregroundStyle(index == current ? Palette.jade : .white.opacity(0.8))
                                .padding(.top, 9)
                        }
                        .offset(x: 20 + CGFloat(index) * stepWidth, y: -20)
                    if index == current {
                        VStack(spacing: 4) {
                            Text("我").font(.caption2.bold())
                            Image(systemName: "figure.walk").font(.system(size: 28, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(width: stepWidth)
                        .offset(x: 20 + CGFloat(index) * stepWidth, y: -height - 29)
                    }
                }
            }
        }
        .frame(height: 295)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.map { "我在第\($0.floor)个虚拟楼层，距下一层\($0.remainingSteps)步" } ?? "楼梯进度尚未读取")
    }
}

@MainActor
private struct IdentitySheet: View {
    @ObservedObject var model: LocalAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("本机身份") {
                    TextField("输入昵称", text: $nickname).textInputAutocapitalization(.never)
                    if let identity = model.identity {
                        LabeledContent("本机编号", value: String(identity.installationID.uuidString.prefix(8)))
                    }
                    Text("1至24个可见字符，不要求唯一。此身份和昵称保存在设备的安全存储中。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = model.identityError {
                        Text(error).foregroundStyle(.red)
                        Button("重试安全存储") { model.reloadIdentity() }
                    }
                    if let message { Text(message).foregroundStyle(.red) }
                    Button(model.identity == nil ? "创建本机身份" : "保存昵称") {
                        if model.saveNickname(nickname) { dismiss() }
                        else { message = "保存未完成。请检查昵称为1至24个可见字符，并确认设备已解锁。" }
                    }.disabled(model.identityError != nil)
                }
                Section("隐私与恢复") {
                    Text("本机进度不需要共享同意，也不会自动公开昵称或健康数据。")
                    Text("本机身份不绑定邮箱，也不支持跨设备找回。丢失安全存储、移除本机身份或重装可能无法恢复原身份；系统是否保留卸载后的Keychain数据不能保证。请勿把本机编号当作账号恢复凭证。联网邮箱账号可在“今日楼层榜”登录或找回密码，不影响本机查看步数。")
                }
            }
            .navigationTitle("本机身份").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .onAppear { nickname = model.identity?.nickname ?? "" }
        }
    }
}
