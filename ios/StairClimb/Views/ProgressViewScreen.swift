import SwiftUI
import UIKit

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
    @State private var showingMotionHelp = false
    private let stepPulse = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var busy: Bool { model.phase == .loading || model.phase == .requesting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    StaircaseView(progress: model.snapshot?.progress, day: model.day.date,
                                  isStale: model.snapshotIsStale)
                    metrics
                    motionStatus
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
        .sheet(isPresented: $showingMotionHelp) { MotionConnectionHelp(model: model) }
        .task { await model.activate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.activate() } }
            else { model.markCached() }
        }
        .onReceive(stepPulse) { _ in
            guard scenePhase == .active, model.hasRequestedMotionAccess else { return }
            Task {
                if model.updateDayIfNeeded() { await model.activate() }
                else { await model.refresh() }
            }
        }
        .task(id: "\(model.day.date):\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            let remaining = max(0.5, model.day.end.timeIntervalSinceNow + 0.05)
            do {
                try await Task.sleep(for: .seconds(remaining))
                if model.updateDayIfNeeded() { await model.activate() }
            } catch {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("本机计步进度", systemImage: "lock.shield")
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

    private var motionStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(statusTitle, systemImage: statusSymbol).font(.headline)
            Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
            if let diagnostic = model.motionDiagnostic {
                Text("错误编号：\(diagnostic)").font(.caption.monospaced()).textSelection(.enabled)
            }
            Button("计步帮助", systemImage: "questionmark.circle") { showingMotionHelp = true }
                .font(.subheadline)
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
                            if !model.hasRequestedMotionAccess { await model.requestMotionAccess() }
                            else { await model.refresh() }
                        }
                    } label: {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "正在更新" : !model.hasRequestedMotionAccess ? "开启本机计步" : "重新读取今日步数")
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    if model.phase != .needsRequest && !busy {
                        Button("运动访问") { Task { await model.requestMotionAccess() } }
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
        case .requesting: "正在请求运动访问"
        case .loading: "正在读取今日步数"
        case .data: "今日进度已更新"
        case .noReadableData: "暂无可读步数"
        case .unavailable: "此设备无法使用运动数据"
        case .failed: "本次更新未完成"
        }
    }

    private var statusDetail: String {
        switch model.phase {
        case .needsRequest: "使用 Core Motion 读取此 iPhone 上海当日累计步数，不读取 Apple 健康。你可自行决定运动访问权限；本机查看无需公开共享。"
        case .requesting: "请在系统弹窗中允许“运动与健身”。拒绝后可在系统设置中重新开启。"
        case .loading: "按上海00:00至当前时间重新查询；过期的昨日结果不会用于今天。"
        case .data: "这里显示此 iPhone 的今日计步，前台每15秒刷新，也可下拉刷新。公开共享和服务器同步状态请查看“今日楼层榜”。"
        case .noReadableData: "当前可读汇总为空，暂显示0步。可能暂无本机计步记录；请确认运动与健身权限已开启并携带手机行走后重试。"
        case .unavailable: "请在支持运动与健身计步的 iPhone 上使用。这里不会生成演示步数。"
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
            Text("每100步兑换1层，是步数游戏换算，不是健康App记录的实际已爬楼层。每日上海00:00重新统计，历史运动数据不会被清除。不采集真实地理位置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// Presentation state only: no Core Motion writes, synthetic steps or network uploads.
@MainActor
private struct StaircaseView: View {
    let progress: StepProgress?
    let day: String
    let isStale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var displayedFloor = 0
    @State private var windowBase = 0
    @State private var selectedFloor: Int?
    @State private var renderedDay: String?
    @State private var replay = 0
    @State private var renderedReplay = 0
    @State private var walking = false
    @State private var stride = false
    @State private var arrival = 0
    @State private var selectionFeedback = 0
    @State private var animationCaption = ""

    private struct PlaybackKey: Equatable {
        let progress: StepProgress?
        let day: String
        let reduceMotion: Bool
        let isStale: Bool
        let active: Bool
        let replay: Int
    }
    private var playbackKey: PlaybackKey {
        PlaybackKey(progress: progress, day: day, reduceMotion: reduceMotion,
                    isStale: isStale, active: scenePhase == .active, replay: replay)
    }
    private var actualFloor: Int { progress?.floor ?? 0 }
    private var viewingFloor: Int { selectedFloor ?? actualFloor }
    private var canInteract: Bool { progress != nil && !walking && scenePhase == .active }

    var body: some View {
        VStack(spacing: 0) {
            scene
            interaction
        }
        .background(Palette.jade)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .task(id: playbackKey) { await updateScene() }
        .sensoryFeedback(.success, trigger: arrival)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
    }

    private var scene: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let stepWidth = max(1, (width - 40) / 5)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Palette.jade, Color(red: 0.04, green: 0.27, blue: 0.29)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("今天的高度").font(.caption.weight(.medium)).opacity(0.8)
                        Spacer()
                        if isStale { Label("缓存进度", systemImage: "clock").font(.caption2) }
                    }
                    Text(progress.map { "\($0.floor)F" } ?? "— F")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(animationCaption.isEmpty ? "点选楼层，左右滑动浏览" : animationCaption)
                        .font(.caption2).opacity(0.85)
                }
                .foregroundStyle(.white).padding(24)
                .accessibilityElement(children: .combine)

                ForEach(0..<5, id: \.self) { index in
                    let floor = windowBase + index
                    let current = floor == actualFloor
                    let selected = floor == viewingFloor
                    let height = CGFloat(44 + index * 27)
                    Button { select(floor) } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(current ? Color.white.opacity(0.96) : Color.white.opacity(selected ? 0.4 : 0.16))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.white.opacity(selected ? 0.85 : 0), lineWidth: 2)
                            }
                            .overlay(alignment: .top) {
                                Text("\(floor)F").font(.caption2.bold()).monospacedDigit()
                                    .foregroundStyle(current ? Palette.jade : .white)
                                    .padding(.top, 9)
                            }
                            .frame(width: max(1, stepWidth - 2), height: height)
                    }
                    .buttonStyle(.plain)
                    .position(x: 20 + (CGFloat(index) + 0.5) * stepWidth, y: 276 - height / 2)
                    .disabled(!canInteract || floor > StaircaseRules.maximumFloor)
                    .accessibilityLabel("第\(floor)层" + (current ? "，我的当前位置" : ""))
                    .accessibilityValue(detail(for: floor))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                if progress != nil && (windowBase...(windowBase + 4)).contains(displayedFloor) {
                    let index = CGFloat(displayedFloor - windowBase)
                    VStack(spacing: 3) {
                        Text(walking ? "向上" : "我").font(.caption2.bold())
                        Image(systemName: stride ? "figure.walk" : "figure.stairs")
                            .font(.system(size: 28, weight: .medium))
                            .rotationEffect(.degrees(walking && stride && !reduceMotion ? -8 : 0))
                    }
                    .foregroundStyle(.white)
                    .position(x: 20 + (index + 0.5) * stepWidth,
                              y: 276 - (44 + index * 27) - 32 - (stride && !reduceMotion ? 5 : 0))
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 26).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                      abs(value.translation.width) > 44 else { return }
                browse(value.translation.width < 0 ? 3 : -3)
            })
        }
        .frame(height: 296)
    }

    private var interaction: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress {
                HStack {
                    Text("下一层 \(actualFloor + 1)F").font(.caption.weight(.semibold))
                    Spacer()
                    Text("还差 \(progress.remainingSteps) 步").font(.caption.monospacedDigit())
                }
                SwiftUI.ProgressView(value: progress.fraction)
                    .tint(.white)
                    .accessibilityLabel("距下一层的步数进度")
                    .accessibilityValue("已完成\(progress.steps % StepRules.stepsPerFloor)步，还差\(progress.remainingSteps)步")
                Text(detail(for: viewingFloor))
                    .font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { browse(-3) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("浏览较低楼层")
                        .disabled(!canInteract || windowBase == 0)
                    Button { returnToMe() } label: {
                        Label("回到我", systemImage: "location.fill").font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                    }.disabled(!canInteract)
                    Spacer(minLength: 0)
                    Button { replay += 1 } label: {
                        Label("回放登梯", systemImage: "play.fill").font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .disabled(!canInteract || reduceMotion || isStale || actualFloor == 0)
                    .accessibilityHint("仅回放最多四层已完成进度，不增加步数或触发同步")
                    Button { browse(3) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }.accessibilityLabel("浏览较高楼层")
                        .disabled(!canInteract || windowBase >= StaircaseRules.maximumBase(near: actualFloor))
                }
                .buttonStyle(.plain)
                Text(reduceMotion ? "已遵循减少动态效果；仍可点选楼层。" : "回放仅展示已完成楼层，不增加运动步数。")
                    .font(.caption2).opacity(0.75)
            } else {
                Label("开启本机计步后，点亮你的第一层", systemImage: "heart")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text("这里不会生成演示步数。")
                    .font(.caption2).opacity(0.75)
            }
        }
        .foregroundStyle(.white).padding(.horizontal, 20).padding(.bottom, 18)
    }

    private func detail(for floor: Int) -> String {
        guard let progress else { return "尚未读取今日步数" }
        if floor == progress.floor {
            return "我在第\(floor)层 · 再走\(progress.remainingSteps)步到下一层"
        }
        if floor < progress.floor { return "第\(floor)层已走过 · 对应\(floor * StepRules.stepsPerFloor)步" }
        return "第\(floor)层尚未到达 · 还需\(floor * StepRules.stepsPerFloor - progress.steps)步"
    }

    private func select(_ floor: Int) {
        guard canInteract else { return }
        selectedFloor = floor
        if !reduceMotion { selectionFeedback += 1 }
    }

    private func browse(_ delta: Int) {
        guard canInteract else { return }
        let next = StaircaseRules.browse(base: windowBase, delta: delta, near: actualFloor)
        change { windowBase = next; selectedFloor = min(next + 2, StaircaseRules.maximumFloor) }
        if !reduceMotion { selectionFeedback += 1 }
    }

    private func returnToMe() {
        change { windowBase = StaircaseRules.centeredBase(actualFloor); selectedFloor = nil }
    }

    private func change(_ action: () -> Void) {
        if reduceMotion { action() }
        else { withAnimation(.spring(response: 0.34, dampingFraction: 0.85), action) }
    }

    private func updateScene() async {
        // SwiftUI cancels the previous task when day, data, visibility or replay changes.
        let sameDay = renderedDay == day
        let previous = sameDay ? displayedFloor : nil
        let isReplay = replay != renderedReplay && sameDay
        renderedReplay = replay
        let plan = StaircaseRules.route(from: previous, to: actualFloor,
                                       replay: isReplay, animated: !reduceMotion && !isStale)
        renderedDay = day
        selectedFloor = nil
        walking = false
        stride = false
        guard progress != nil, scenePhase == .active else {
            displayedFloor = actualFloor
            windowBase = StaircaseRules.centeredBase(actualFloor)
            animationCaption = progress == nil ? "等待真实今日步数" : ""
            return
        }
        displayedFloor = plan[0]
        windowBase = max(0, min(StaircaseRules.maximumFloor - 4, displayedFloor - 1))
        if plan.count == 1 {
            windowBase = StaircaseRules.centeredBase(actualFloor)
            animationCaption = isStale ? "上次读取的缓存，刷新后查看新进度" : "点选楼层，左右滑动浏览"
            return
        }
        walking = true
        animationCaption = isReplay ? "已完成进度回放 · 不计入步数" : "向上前进 · 展示最近\(plan.count - 1)层"
        defer { walking = false; stride = false }
        do {
            for floor in plan.dropFirst() {
                try await Task.sleep(for: .milliseconds(320))
                try Task.checkCancellation()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    if floor > windowBase + 4 { windowBase = floor - 3 }
                    displayedFloor = floor
                    stride.toggle()
                }
            }
            try Task.checkCancellation()
            if !isReplay && sameDay && previous.map({ actualFloor > $0 }) == true {
                arrival += 1
            }
            animationCaption = isReplay ? "回放结束 · 步数未改变" : "已到达第\(actualFloor)层"
        } catch {
            // A newer query/day/background state owns the next scene. No model writes.
        }
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
                    Text("本机进度不需要共享同意，也不会自动公开昵称或运动数据。")
                    Text("本机身份不绑定邮箱，也不支持跨设备找回。丢失安全存储、移除本机身份或重装可能无法恢复原身份；系统是否保留卸载后的Keychain数据不能保证。请勿把本机编号当作账号恢复凭证。联网邮箱账号可在“今日楼层榜”登录或找回密码，不影响本机查看步数。")
                }
            }
            .navigationTitle("本机身份").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .onAppear { nickname = model.identity?.nickname ?? "" }
        }
    }
}


@MainActor
private struct MotionConnectionHelp: View {
    @ObservedObject var model: LocalAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("开启本机计步") {
                    Text("本应用使用 Core Motion 的系统计步，不连接 Apple 健康，不合并 Apple Watch 或其他设备的数据。请携带此 iPhone 行走。")
                    Text("首次点击“开启本机计步”会请求运动与健身权限。如果曾拒绝，请到系统设置的“隐私与安全性 → 运动与健身”中允许爬楼梯。")
                    Button("开启本机计步") { Task { await model.requestMotionAccess() } }
                        .disabled(model.phase == .requesting || model.phase == .loading || model.phase == .unavailable)
                    Link("打开本应用设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                    Text("系统菜单名称可能随 iOS 版本变化，运动权限也可在隐私与安全性中查找。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("刷新与设备") {
                    Text("前台约每15秒查询一次今日累计值，重复刷新不会叠加计步。应用挂起时不保证实时回调；返回前台会补查当天的系统记录。")
                    Text("系统通常提供最近7天的本机计步历史。本页只查询上海时间今天，不会导入其他设备汇总。")
                    Text("模拟器不提供真实计步；本应用无需 HealthKit 描述文件，但 iPhone 安装包仍需正常签名。设备管理策略也可能限制运动访问。")
                }
                Section("排查信息") {
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                    LabeledContent("应用版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    LabeledContent("构建号", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                    LabeledContent("应用标识", value: Bundle.main.bundleIdentifier ?? "—")
                    if let diagnostic = model.motionDiagnostic {
                        Text("错误编号：\(diagnostic)").textSelection(.enabled)
                    }
                    Text("反馈时可提供上方错误编号和安装方式，无需发送运动记录或账号凭证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("计步帮助")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
