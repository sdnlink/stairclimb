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
                    Text("只显示真实成员，小圈不凑人数。历史健康数据不清除；这里不提供即时聊天或真实地理位置。")
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
                        Text("请先注册、验证邮箱并登录；登录不等于健康共享或参加圈子。不参加仍可在“我的楼梯”查看本机运动。")
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
                    Button("读取、同步并刷新今日圈子") { Task { await refresh() } }.disabled(model.busy)
                    if model.circleParticipating == true || model.state.identity?.user.sharingEnabled == true {
                        Button("退出圈子并撤回共享", role: .destructive) { leaving = true }
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
                Text("按每日1000步区间公开分组。昵称、当日汇总步数和虚拟楼层会对圈友可见；每天自动匹配，跨区间自动迁圈。允许本地运动而不参加；退出同时撤回健康汇总共享。")
            }
            .alert("退出圈子并撤回共享？", isPresented: $leaving) {
                Button("确认退出", role: .destructive) { Task { await model.privacy(.revoke, confirmNewAttempt: true) } }
                Button("取消", role: .cancel) {}
            } message: { Text("立即停止本机上传；服务器确认前显示待完成。重新共享和重新参加都需要主动同意。") }
        }
    }
}
