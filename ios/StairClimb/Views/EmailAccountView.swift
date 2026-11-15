import SwiftUI

@MainActor
struct EmailAccountView: View {
    @ObservedObject var model: SocialModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var action: EmailAction = .login
    @State private var address = ""
    @State private var email = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var proof = ""
    @State private var confirmIndependent = false
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            Form {
                if let identity = model.state.identity {
                    Section("当前账号") {
                        LabeledContent("昵称", value: identity.user.nickname)
                        Text(identity.baseURL).font(.caption).textSelection(.enabled)
                        if model.isLegacyIdentity {
                            Text("这是原有本机身份。绑定邮箱并验证时必须保留本机Keychain凭证；验证后登录同一账号，原昵称、历史与隐私选择不丢失。")
                        } else {
                            if let email = model.accountEmail { LabeledContent("本人邮箱", value: email) }
                            Button("读取本人账号邮箱") { Task { await model.loadAccount() } }.disabled(model.busy)
                            Text("邮箱仅在此账号设置显示，不出现在排行榜或圈友中。")
                            Button(model.state.logoutPending == true ? "重试确认退出全部会话" : "退出全部设备会话", role: .destructive) { confirmLogout = true }
                                .disabled(model.state.privacy != nil || !model.storageReady)
                            if model.state.logoutPending == true {
                                Text("退出待确认，已停止本机上传。会话失效时先重新登录同一账号，再确认退出。")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Section("邮箱账号操作") {
                    Picker("操作", selection: $action) {
                        ForEach(EmailAction.allCases.filter { $0 != .bind || model.isLegacyIdentity }) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }.disabled(model.busy)
                    if model.state.identity == nil {
                        TextField("HTTPS服务根地址", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(model.busy)
                        Text("开发设备须安装并信任本地CA；地址必须与证书匹配。127.0.0.1在iPhone上指手机自身。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if action.needsEmail {
                        TextField("邮箱（不公开）", text: $email)
                            .keyboardType(.emailAddress).textContentType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.busy)
                    }
                    if action.needsNickname {
                        TextField("公开昵称（可使用化名）", text: $nickname).disabled(model.busy)
                    }
                    if action.needsPassword {
                        SecureField(action == .reset || action == .independent ? "新密码（12至128字符）" : "密码（12至128字符）", text: $password)
                            .textContentType(action == .register || action == .reset || action == .bind || action == .independent ? .newPassword : .password)
                            .disabled(model.busy)
                    }
                    if action.needsProof {
                        SecureField("邮件中的43位一次性凭据", text: $proof)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.busy)
                        Text("凭据15分钟有效且仅能使用一次。重发后用最新邮件；验证邮箱还需注册密码。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if action == .independent {
                        Text("仅当邮箱被他人的未验证旧身份占用：先申请找回邮件，凭收到的重置凭据创建独立账号。不会取得、复制或删除旧设备数据。")
                            .font(.caption)
                    }
                    Button(action.title) {
                        if action == .independent { confirmIndependent = true }
                        else { submit() }
                    }.disabled(model.busy || !model.storageReady)
                    if model.busy { HStack { ProgressView(); Text("等待服务器确认，请勿重复提交") } }
                }
                if let status = model.authMessage {
                    Section("账号操作结果") { Text(status).accessibilityLabel("账号操作结果：\(status)") }
                }
                if let status = model.message { Section("网络状态") { Text(status) } }
                Section("字段用途与隐私") {
                    Text("邮箱用于验证、登录和找回；密码不持久保存在App，验证/重置凭据仅用于本次请求。仅必要会话凭据保存于本机Keychain，不跨设备同步。")
                    Text("昵称及当日汇总只在另行主动共享后公开。注册、验证和登录均不会自动开启健康共享或参加圈子；未登录仍能使用“我的楼梯”。")
                    Text("发送成功仅表示邮件服务器接受，不表示收件或验证成功。邮件未到可重发；限流时等待5分钟。账号设置关闭或切后台会清除表单密码与邮件凭据。")
                    Text("退出撤销全部会话，但保留已共享数据；可先在榜单页撤回或删除。删除账号会清除邮箱、认证信息及全部共享历史，不操作Apple健康数据。已验证邮箱可重新登录或找回；旧匿名身份丢失凭证无法保证恢复。")
                }.font(.caption)
            }
            .navigationTitle("邮箱与账号")
            .onChange(of: action) { _, _ in clearSecrets() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { clearSecrets() } }
            .onDisappear { clearSecrets(); email = ""; model.hideAccountEmail() }
            .alert("创建全新独立账号？", isPresented: $confirmIndependent) {
                Button("凭邮箱归属创建", role: .destructive) { submit() }
                Button("取消", role: .cancel) {}
            } message: { Text("仅解除尚未验证的旧身份邮箱关联，不合并旧设备数据；完成后仍需登录，默认不共享。") }
            .confirmationDialog("退出全部设备会话？共享历史仍保留。", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("确认退出全部会话", role: .destructive) { clearSecrets(); Task { await model.logout() } }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func clearSecrets() { password = ""; proof = "" }

    private func submit() {
        // Capture this submission, then clear fields immediately; no secrets in model state.
        let selected = action, enteredPassword = password, enteredProof = proof
        let enteredAddress = address, enteredEmail = email, enteredNickname = nickname
        clearSecrets()
        Task {
            await model.emailAction(selected, address: enteredAddress, email: enteredEmail,
                                    password: enteredPassword, nickname: enteredNickname, proof: enteredProof)
        }
    }
}
