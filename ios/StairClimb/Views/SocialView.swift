import SwiftUI

@MainActor
struct SocialView: View {
    @ObservedObject var model: SocialModel
    @ObservedObject var local: LocalAppModel
    @State private var address = ""
    @State private var nickname = ""
    @State private var confirmation: Confirmation?

    private enum Confirmation: String, Identifiable {
        case share, revoke, deleteSteps, deleteAccount, forget
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                if !model.storageReady {
                    Section("安全存储未就绪") {
                        Text("网络操作与上传已停止。解锁设备后重试，不会自动注册替代账号。")
                        Button("重试安全存储") { model.retrySecureStorage() }
                    }
                }
                if let identity = model.state.identity {
                    identitySection(identity)
                    sharingSection(identity)
                    leaderboard
                    privacySection
                } else {
                    Section("创建联网身份") {
                        Text("无需邮箱或手机号。注册默认不公开；不注册仍能在“我的楼梯”查看本机运动。")
                        TextField("服务根地址，例如 https://你的服务", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("联网昵称", text: $nickname)
                        Text("连接须使用HTTPS，开发证书需在设备安装并信任CA。127.0.0.1指手机本身；真机请用证书覆盖的Linux局域网地址或域名。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("注册并安全保存凭证") {
                            Task { await model.register(address: address, nickname: nickname) }
                        }.disabled(model.busy || !model.storageReady)
                    }
                }
                if let message = model.message {
                    Section("操作状态") { Text(message).font(.subheadline).accessibilityLabel("操作状态：\(message)") }
                }
                if model.busy { Section { HStack { ProgressView(); Text("正在与服务器确认，请稍候") } } }
                Section("可见性与虚拟楼层") {
                    Text("仅展示仍同意共享的用户，今日未同步者显示0步/0层。相同步数同名次，次序按稳定用户编号。所有楼层是每100步换算的游戏楼层，不涉及实际楼层或真实位置。")
                        .font(.caption)
                }
            }
            .navigationTitle("今日楼层榜")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") { Task { await model.refresh() } }
                        .disabled(model.busy || model.state.identity == nil || !model.storageReady)
                }
            }
            .refreshable { await model.refresh() }
            .task {
                nickname = model.state.identity?.user.nickname ?? local.identity?.nickname ?? ""
                await model.refresh()
            }
            .alert(item: $confirmation) { choice in
                switch choice {
                case .share:
                    Alert(title: Text("同意公开健康汇总？"), message: Text("昵称、当日汇总步数和虚拟楼层将对其他用户可见。仅上传累计总数，不上传原始健康样本或地理位置。重新共享会再次公开服务器保留的当日数据；圈子还需单独主动同意。拒绝仍可本机查看运动。"), primaryButton: .default(Text("主动同意共享")) { Task { await model.consentToShare() } }, secondaryButton: .cancel(Text("暂不共享")))
                case .revoke:
                    privacyAlert(title: "撤回共享？", detail: "本机立即停止上传；服务器确认后移除公开榜单及圈子资格。历史已存值保留为私有。网络失败会显示待完成。", kind: .revoke)
                case .deleteSteps:
                    privacyAlert(title: "删除全部共享步数？", detail: "删除服务器全部日期的步数，关闭共享与圈子参与，保留账号。不删除Apple健康数据。若上次结果未知，本次确认表示重新删除服务器现存数据。", kind: .deleteSteps)
                case .deleteAccount:
                    privacyAlert(title: "永久删除联网账号？", detail: "删除服务器身份、昵称、共享与圈子状态及全部步数，旧凭证失效。无法恢复，不影响本机Apple健康数据；网络失败不表示完成。", kind: .deleteAccount)
                case .forget:
                    Alert(title: Text("仅移除此机凭证？"), message: Text("这不删除或撤回服务器公开数据。丢失凭证后没有账号找回，重装和跨设备恢复均不保证。请优先使用删除账号。"), primaryButton: .destructive(Text("移除且不再找回")) { model.forgetLocalCredential() }, secondaryButton: .cancel())
                }
            }
        }
    }

    private func identitySection(_ identity: NetworkIdentity) -> some View {
        Section("联网身份") {
            LabeledContent("服务", value: identity.baseURL)
                .font(.caption).textSelection(.enabled)
            LabeledContent("昵称", value: identity.user.nickname)
            TextField("修改联网昵称", text: $nickname)
            Button("保存联网昵称") { Task { await model.rename(nickname) } }
                .disabled(model.busy || !model.authenticated || model.state.privacy != nil)
            Text("凭证只保存在Keychain，与此服务地址绑定。要更换服务先处理旧账号及数据，再移除此机凭证。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sharingSection(_ identity: NetworkIdentity) -> some View {
        Section("健康汇总共享") {
            LabeledContent("服务器共享", value: identity.user.sharingEnabled ? "公开（刷新确认）" : "未公开（刷新确认）")
            LabeledContent("本机上传", value: model.canUpload ? "已允许" : "已停止")
            if !model.canUpload && model.state.privacy == nil {
                Button("了解并同意共享") { confirmation = .share }
                    .disabled(model.busy || !model.authenticated || !model.storageReady)
            }
            Button("读取今日步数并同步") { Task { await model.sync(local: local) } }
                .disabled(model.busy || !model.canUpload)
            if let date = model.syncedDate, let steps = model.syncedSteps {
                Text("服务器已确认 \(date) · \(steps)步").font(.caption).foregroundStyle(.green)
            } else {
                Text("尚无本次确认的今日同步结果。无可读健康数据或读取失败时不上传临时0值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("撤回共享并停止上传", role: .destructive) { confirmation = .revoke }
            // Remains available during an in-flight upload: the model stops locally first.
        }
    }

    private var leaderboard: some View {
        Section {
            if let date = model.boardDate {
                Text("\(date) · 上海 Asia/Shanghai · 公开用户\(model.total)人")
                    .font(.caption).foregroundStyle(.secondary)
                if let updated = model.boardUpdatedAt {
                    Text("\(model.boardIsStale ? "缓存，尚未刷新成功" : "服务器读取") · 上海 \(ShanghaiDay.timeLabel(for: updated))")
                        .font(.caption).foregroundStyle(model.boardIsStale ? .orange : .secondary)
                }
                ForEach(model.entries) { entry in
                    HStack(spacing: 12) {
                        Text("\(entry.rank ?? entry.position)").font(.headline.monospacedDigit()).frame(minWidth: 25)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.nickname + (entry.isMe ? " · 我" : ""))
                                .fontWeight(entry.isMe ? .bold : .regular)
                            Text("\(entry.steps)步 · 第\(entry.floor)个虚拟楼层")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.isMe { Image(systemName: "person.fill.checkmark").foregroundStyle(.teal) }
                    }.listRowBackground(entry.isMe ? Color.teal.opacity(0.08) : nil)
                }
                if model.entries.isEmpty { Text("今日还没有公开共享的用户。") }
                if model.nextCursor != nil {
                    Button("加载下一页") { Task { await model.loadMore() } }.disabled(model.busy)
                } else { Text("已到本页序列末尾").font(.caption).foregroundStyle(.secondary) }
            } else { Text("点击刷新读取服务器今日榜单；离线时不会展示假用户。") }
            Button("定位本人所在页") { Task { await model.locateMe() } }
                .disabled(model.busy || !model.authenticated)
            Text("榜单变动会清空过期分页，请重新刷新。定位本人后可刷新首页遍历全部用户。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("真实联网排行榜") }
    }

    private var privacySection: some View {
        Section("隐私与删除") {
            if let pending = model.state.privacy {
                Text("隐私操作待确认。本机保持停止上传；刷新、重启或回前台不会自动开启共享。")
                    .foregroundStyle(.orange)
                Button("继续确认待完成操作") { Task { await model.privacy(pending.kind) } }
                    .disabled(model.busy || !model.storageReady)
            }
            Button("删除全部已共享步数", role: .destructive) { confirmation = .deleteSteps }
            Button("删除联网账号及所有数据", role: .destructive) { confirmation = .deleteAccount }
            Button("仅移除此机联网凭证", role: .destructive) { confirmation = .forget }
                .disabled(model.busy || model.state.privacy != nil || !model.storageReady)
            Text("网络失败不会显示删除完成。其他人已看到或保存的内容无法收回。没有邮箱/手机号找回，退出、丢失凭证或重装可能永久失去账号操作权。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func privacyAlert(title: String, detail: String, kind: PrivacyKind) -> Alert {
        Alert(title: Text(title), message: Text(detail),
              primaryButton: .destructive(Text("确认")) { Task { await model.privacy(kind, confirmNewAttempt: true) } },
              secondaryButton: .cancel())
    }
}

@MainActor
struct AppShell: View {
    @ObservedObject var local: LocalAppModel
    @ObservedObject var social: SocialModel
    @Environment(\.scenePhase) private var scenePhase
    private let pulse = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            ProgressViewScreen(model: local)
                .tabItem { Label("我的楼梯", systemImage: "figure.stairs") }
            SocialView(model: social, local: local)
                .tabItem { Label("今日楼层榜", systemImage: "list.number") }
            CircleView(model: social, local: local)
                .tabItem { Label("运动圈子", systemImage: "person.3") }
        }
        .tint(.teal)
        .task { await social.foreground(local: local) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await social.foreground(local: local) } }
        }
        .onChange(of: local.day) { _, _ in
            social.dayChanged()
            Task { await social.foreground(local: local) }
        }
        .onReceive(pulse) { _ in
            guard scenePhase == .active else { return }
            social.dayChangedIfNeeded()
            local.updateDayIfNeeded()
        }
    }
}
