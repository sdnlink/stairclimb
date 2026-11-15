import SwiftUI

@MainActor
struct CircleView: View {
    @ObservedObject var model: SocialModel
    @ObservedObject var local: LocalAppModel
    @State private var consent = false
    @State private var leaving = false
    @State private var showAccount = false

    private func refresh() async {
        await model.foreground(local: local)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("每日自动匹配") {
                    Text("上海 Asia/Shanghai 每天00:00重新匹配，每\(StepRules.circleBandSteps)步一组：0–999、1000–1999等。同组就是同一天的同一频道；跨区间同步后自动迁圈。")
                    Text("只显示真实成员，小圈不凑人数。历史运动数据不清除；不公开真实地理位置。交流功能暂未开放。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.storageReady {
                    Section("安全存储未就绪") {
                        Text("网络操作与上传已停止。请解锁设备后重试；本机运动仍可独立查看。")
                        Button("重试安全存储") { model.retrySecureStorage() }
                    }
                } else if model.state.logoutPending == true {
                    Section("退出等待确认") {
                        Text("本机已停止上传，旧圈友已清除。服务器尚未确认退出，不能自动重新参加。")
                        Button("重试退出") { Task { await model.logout() } }.disabled(model.busy)
                        Button("登录同一账号以处理待完成退出") { showAccount = true }.disabled(model.busy)
                    }
                } else if model.state.privacy != nil {
                    Section("隐私操作待确认") {
                        Text("本机已停止上传，圈子缓存已清除。请在今日楼层榜继续确认；不会自动重新参加。")
                    }
                } else if model.state.identity == nil || !model.authenticated {
                    Section("验证邮箱后查看圈友") {
                        Text("请先注册、验证邮箱并登录；登录不等于运动共享或参加圈子。不参加仍可在“我的楼梯”查看本机运动。")
                        Button(model.isLegacyIdentity ? "绑定旧身份邮箱" : "注册、验证或登录") { showAccount = true }
                            .disabled(model.busy)
                        if model.state.identity != nil {
                            Button("刷新已有会话") { Task { await refresh() } }.disabled(model.busy)
                        }
                    }
                } else {
                    if let channel = model.circle {
                        Section("今日频道") {
                            Text(channel.id).font(.caption.monospaced()).textSelection(.enabled)
                            LabeledContent("步数区间", value: "\(channel.minSteps)–\(channel.maxSteps)步")
                            LabeledContent("真实人数", value: "\(model.circleTotal)人")
                            Text("\(channel.date) · 上海日期").font(.caption)
                            ForEach(model.circleMembers) { member in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(member.nickname + (member.isMe ? " · 我" : ""))
                                        .fontWeight(member.isMe ? .bold : .regular)
                                    Text("\(member.steps)步 · \(member.floor)个虚拟楼层")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if model.circleMembers.isEmpty { Text("当前页暂无成员，请刷新。") }
                            if model.circleNext != nil {
                                Button("加载更多圈友") { Task { await model.refreshCircle(more: true) } }.disabled(model.busy)
                            } else { Text("已到末页").font(.caption) }
                            Button("定位圈内本人") { Task { await model.refreshCircle(locate: true) } }.disabled(model.busy)
                        }
                    } else {
                        Section(model.circleParticipating == false ? "尚未参加" : "等待读取今日圈子") {
                            Text("共享排行榜不等于同意参加圈子。先在今日楼层榜同意共享，再在此主动确认参加。")
                            Button("了解并主动参加") { consent = true }.disabled(model.busy || !model.canUpload)
                        }
                    }
                    if CommunityFeatures.chatEnabled, let channel = model.circle {
                        CircleConversation(model: model, channel: channel).id(channel.id)
                    }
                    Button("读取、同步并刷新今日圈子") { Task { await refresh() } }.disabled(model.busy)
                    if model.circleParticipating == true || model.state.identity?.user.sharingEnabled == true {
                        Button("退出圈子并撤回共享", role: .destructive) { leaving = true }
                    }
                }
                if model.circleUpdatedAt != nil || model.circleNotice != nil {
                    Section("刷新与匹配状态") {
                        if let updated = model.circleUpdatedAt {
                            Text("上次成功刷新 · 上海 \(ShanghaiDay.timeLabel(for: updated))")
                                .font(.caption).foregroundStyle(.secondary)
                            if model.circleIsStale {
                                Text(model.circle == nil ? "上次结果已过期，旧圈友已隐藏；请刷新确认今日频道。" : "缓存圈友，尚未重新刷新成功；成员可能已变化。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if let notice = model.circleNotice { Text(notice).font(.subheadline) }
                    }
                }
                if model.busy { HStack { ProgressView(); Text("正在确认服务器状态") } }
                if let error = model.circleError { Section("未完成") { Text(error); Text("请检查网络后刷新，旧频道不会当作今日结果。") } }
                if let message = model.message { Section("操作状态") { Text(message).font(.caption) } }
            }
            .navigationTitle("今日运动圈子")
            .refreshable { await refresh() }
            .task { await model.refreshCircle() }
            .sheet(isPresented: $showAccount) { EmailAccountView(model: model) }
            .alert("主动同意参加运动圈子？", isPresented: $consent) {
                Button("主动同意参加") { Task { await model.joinCircle(); await model.refreshCircle() } }
                Button("暂不参加", role: .cancel) {}
            } message: {
                Text("按每日1000步区间公开分组。昵称、当日汇总步数和虚拟楼层会对圈友可见；每天自动匹配，跨区间自动迁圈。允许本地运动而不参加；退出同时撤回运动汇总共享。")
            }
            .alert("退出圈子并撤回共享？", isPresented: $leaving) {
                Button("确认退出", role: .destructive) { Task { await model.privacy(.revoke, confirmNewAttempt: true) } }
                Button("取消", role: .cancel) {}
            } message: { Text("立即停止本机上传；服务器确认前显示待完成。重新共享和重新参加都需要主动同意。") }
        }
    }
}

@MainActor
private struct CircleConversation: View {
    @ObservedObject var model: SocialModel
    let channel: CircleChannel
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var draft = ""
    @State private var clientID = UUID()
    @State private var reply: CircleMessage?
    @State private var reporting: CircleMessage?
    @State private var blocking: CircleMessage?
    @State private var retracting: CircleMessage?

    private var polling: Bool { visible && scenePhase == .active }

    var body: some View {
        Section("圈友交流") {
            Text("和今天步数相近的人聊聊运动。消息对本频道圈友可见，请勿发送邮箱、电话或住址。")
                .font(.caption).foregroundStyle(.secondary)
            if model.chatBefore != nil {
                Button("查看更早的消息") { Task { await model.refreshChat(older: true) } }.disabled(model.busy)
            }
            if model.chatMessages.isEmpty {
                ContentUnavailableView("还没有聊天消息", systemImage: "bubble.left.and.bubble.right",
                    description: Text("聊聊今天走了多少步，或给圈友一句鼓励。"))
            }
            ForEach(model.chatMessages) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.isMe ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.title2).foregroundStyle(item.isMe ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.nickname + (item.isMe ? " · 我" : "")).font(.subheadline.bold())
                            Spacer()
                            Text(ShanghaiDay.timeLabel(for: Date(timeIntervalSince1970: TimeInterval(item.createdAt))))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let id = item.replyTo, !item.deleted {
                            Text("回复消息 #\(id)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.deleted ? "这条消息已撤回" : item.text)
                            .foregroundStyle(item.deleted ? .secondary : .primary)
                            .textSelection(.enabled)
                        if !item.deleted {
                            HStack {
                                Button("回复") { reply = item; clientID = UUID() }
                                    .buttonStyle(.borderless).disabled(!model.canChat)
                                Spacer()
                                Menu {
                                    if item.isMe {
                                        Button("撤回消息", role: .destructive) { retracting = item }
                                    } else {
                                        Button("举报消息", systemImage: "flag") { reporting = item }
                                        Button("屏蔽此人", systemImage: "person.crop.circle.badge.xmark", role: .destructive) { blocking = item }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                                }.accessibilityLabel("消息操作，\(item.nickname)").disabled(model.busy)
                            }.font(.caption)
                        }
                    }
                }.padding(.vertical, 4)
            }
            if let reply {
                HStack {
                    Text("正在回复 \(reply.nickname) · #\(reply.id)").font(.caption)
                    Spacer()
                    Button("取消回复") { self.reply = nil; clientID = UUID() }.font(.caption)
                }
            }
            TextField("说点什么，鼓励一下圈友…", text: $draft, axis: .vertical)
                .lineLimit(2...5).disabled(!model.canChat)
                .onChange(of: draft) { _, _ in clientID = UUID() }
            HStack {
                Text("\(draft.unicodeScalars.count)/1000字").font(.caption).foregroundStyle(draft.unicodeScalars.count > 1000 ? .red : .secondary)
                Spacer()
                Button("发送", systemImage: "paperplane.fill") {
                    let sentID = clientID, text = draft, replyID = reply?.id
                    Task {
                        if await model.sendChat(text: text, replyTo: replyID, clientID: sentID), clientID == sentID {
                            draft = ""; reply = nil; clientID = UUID()
                        }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.busy || !model.canChat || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.unicodeScalars.count > 1000)
            }
            if let notice = model.chatNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Button("刷新聊天") { Task { await model.refreshChat(reset: true) } }.disabled(model.busy)
            Text("停留本页时约每5秒刷新；迁圈或跨日后进入新的聊天频道。")
                .font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup("屏蔽管理") {
                Button("读取已屏蔽用户") { Task { await model.chatAction(.listBlocks) } }.disabled(model.busy)
                ForEach(model.blockedUsers) { user in
                    HStack {
                        Text(user.nickname)
                        Spacer()
                        Button("取消屏蔽") { Task { await model.chatAction(.block(user.userId, false)); await model.refreshChat(reset: true) } }
                            .disabled(model.busy)
                    }
                }
                Text("屏蔽影响双方圈子聊天，不影响排行榜。只有你能查看自己的屏蔽列表。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: polling) {
            guard polling else { return }
            while !Task.isCancelled {
                await model.refreshChat()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .confirmationDialog("举报这条消息", isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } }), titleVisibility: .visible) {
            if let item = reporting {
                Button("垃圾信息或广告") { Task { await model.chatAction(.report(item.id, "spam")) } }
                Button("辱骂或骚扰") { Task { await model.chatAction(.report(item.id, "abuse")) } }
                Button("其他不当内容") { Task { await model.chatAction(.report(item.id, "other")) } }
            }
            Button("取消", role: .cancel) { reporting = nil }
        }
        .alert("屏蔽这位圈友？", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } })) {
            if let item = blocking {
                Button("确认屏蔽", role: .destructive) { Task { await model.chatAction(.block(item.authorId, true)); await model.refreshChat(reset: true) } }
            }
            Button("取消", role: .cancel) { blocking = nil }
        } message: { Text("双方后续将互相隐藏圈子消息，可在屏蔽管理中取消。") }
        .alert("撤回这条消息？", isPresented: Binding(get: { retracting != nil }, set: { if !$0 { retracting = nil } })) {
            if let item = retracting {
                Button("撤回", role: .destructive) { Task { await model.chatAction(.retract(item.id)) } }
            }
            Button("取消", role: .cancel) { retracting = nil }
        } message: { Text("服务器将清空消息正文，圈友刷新后会看到撤回提示。") }
    }
}
