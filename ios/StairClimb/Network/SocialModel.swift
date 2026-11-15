import Foundation
import Combine

@MainActor
final class SocialModel: ObservableObject {
    @Published private(set) var state = SavedNetworkState()
    @Published private(set) var busy = false
    @Published private(set) var storageReady = true
    @Published private(set) var message: String?
    @Published private(set) var entries: [LeaderboardEntry] = []
    @Published private(set) var boardDate: String?
    @Published private(set) var boardUpdatedAt: Date?
    @Published private(set) var boardIsStale = false
    @Published private(set) var total = 0
    @Published private(set) var nextCursor: String?
    @Published private(set) var snapshot: String?
    @Published private(set) var syncedDate: String?
    @Published private(set) var syncedSteps: Int?
    @Published private(set) var syncedAt: Date?
    @Published private(set) var syncIsStale = false
    @Published private(set) var authenticated = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var authMessage: String?
    @Published private(set) var circle: CircleChannel?
    @Published private(set) var circleMembers: [LeaderboardEntry] = []
    @Published private(set) var circleTotal = 0
    @Published private(set) var circleNext: String?
    @Published private(set) var circleVersion: String?
    @Published private(set) var circleParticipating: Bool?
    @Published private(set) var circleError: String?
    @Published private(set) var circleUpdatedAt: Date?
    @Published private(set) var circleIsStale = false
    @Published private(set) var circleNotice: String?

    @Published private(set) var chatMessages: [CircleMessage] = []
    @Published private(set) var chatBefore: Int?
    @Published private(set) var chatNotice: String?
    @Published private(set) var blockedUsers: [BlockedCircleUser] = []
    @Published private(set) var chatPolling = false
    private var chatWatermark: Int?
    private var chatEpoch = UUID()

    var showGlobalBusy: Bool { busy && !chatPolling }

    let pageSize = 20
    private let vault: NetworkVault
    private let defaults: UserDefaults
    private static let uploadStopKey = "networkUploadStopped"
    private let clock: () -> Date
    private let clientFactory: @MainActor (URL) -> any APIRequesting
    private var client: (any APIRequesting)?
    private var epoch = UUID()
    private var accountReadID = UUID()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var privacyRunning = false
    private var failedInitialLoad = false
    private var currentDay: ShanghaiDay

    init(vault: NetworkVault, defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         clientFactory: @escaping @MainActor (URL) -> any APIRequesting = { APIClient(baseURL: $0) }) {
        self.vault = vault
        self.defaults = defaults
        self.clock = clock
        self.currentDay = ShanghaiDay(containing: clock())
        self.clientFactory = clientFactory
        do {
            state = try vault.load()
            if defaults.bool(forKey: Self.uploadStopKey) { state.uploadAllowed = false }
            if let identity = state.identity {
                client = clientFactory(try ServiceAddress.validated(identity.baseURL))
            }
        } catch {
            failedInitialLoad = true
            storageReady = false
            message = NetworkFailure.storage.localizedDescription
        }
    }

    var isLegacyIdentity: Bool { state.identity != nil && state.identity?.refreshToken == nil }

    var canUpload: Bool {
        storageReady && authenticated && !isLegacyIdentity && state.uploadAllowed && state.privacy == nil
            && state.logoutPending != true && state.identity?.refreshUncertain != true
            && state.identity?.user.sharingEnabled == true
    }

    func retrySecureStorage() {
        do {
            if failedInitialLoad {
                state = try vault.load()
                if defaults.bool(forKey: Self.uploadStopKey) { state.uploadAllowed = false }
                if let identity = state.identity { client = clientFactory(try ServiceAddress.validated(identity.baseURL)) }
            } else { try vault.save(state) }
            failedInitialLoad = false
            storageReady = true
            message = "安全存储已就绪，请刷新连接。"
        } catch { message = NetworkFailure.storage.localizedDescription }
    }

    private func persist() throws {
        do { try vault.save(state) }
        catch {
            storageReady = false
            throw NetworkFailure.storage
        }
    }

    private func clearBoard(preservingSuccess: Bool = false, circleNotice: String? = nil) {
        entries = []; boardDate = nil; snapshot = nil; nextCursor = nil; total = 0
        if !preservingSuccess { boardUpdatedAt = nil }
        boardIsStale = boardUpdatedAt != nil
        clearCircle(preservingSuccess: preservingSuccess, notice: circleNotice)
    }

    private func clearCircle(preservingSuccess: Bool = false, notice: String? = nil) {
        clearChat()
        circle = nil; circleMembers = []; circleTotal = 0; circleNext = nil
        circleVersion = nil; circleParticipating = nil; circleError = nil
        if !preservingSuccess { circleUpdatedAt = nil }
        circleIsStale = circleUpdatedAt != nil
        circleNotice = notice
    }

    private func clearSync() {
        syncedDate = nil; syncedSteps = nil; syncedAt = nil; syncIsStale = false
    }

    func markCached() {
        if boardUpdatedAt != nil { boardIsStale = true }
        if circleUpdatedAt != nil { circleIsStale = true }
        if syncedAt != nil { syncIsStale = true }
    }

    func dayChanged() {
        currentDay = ShanghaiDay(containing: clock())
        epoch = UUID()
        clearBoard(circleNotice: "上海00:00开始新一天，昨日圈友已清除；重新读取今日步数后自动匹配。")
        clearSync()
    }

    private func checkDay(_ response: APIEnvelope) throws {
        try response.validateRules()
        guard response.date == ShanghaiDay(containing: clock()).date else {
            dayChanged()
            throw NetworkFailure.dayChanged
        }
    }

    private func finish() {
        busy = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func waitForIdle() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
    }

    private func handle(_ error: Error) {
        let failure = error as? NetworkFailure ?? .transport
        if boardDate != nil { boardIsStale = true }
        if [.unauthorized, .consentChanged, .sessionUncertain, .emailRequired].contains(failure) {
            defaults.set(true, forKey: Self.uploadStopKey)
            state.uploadAllowed = false
            authenticated = false
            try? persist()
            clearBoard()
            clearSync()
        }
        if failure == .pageChanged { clearBoard(preservingSuccess: true, circleNotice: circleNotice) }
        if failure == .dayChanged { dayChanged() }
        message = failure.localizedDescription
    }

    private func call(_ request: APIRequest) async throws -> APIEnvelope {
        guard storageReady, let client, state.identity != nil else { throw NetworkFailure.storage }
        let ticket = epoch
        var rotated = false
        if state.identity?.refreshToken != nil {
            guard state.identity?.refreshUncertain != true else { throw NetworkFailure.sessionUncertain }
            if (state.identity?.accessExpiresAt ?? .distantPast) <= clock().addingTimeInterval(30) {
                try await rotateSession()
                rotated = true
            }
        }
        guard ticket == epoch else { throw state.privacy == nil ? NetworkFailure.dayChanged : .pendingPrivacy }
        do { return try await client.send(request, token: state.identity!.token) }
        catch NetworkFailure.unauthorized {
            // Only retry a read. Never replay a health snapshot or destructive operation.
            guard request.method == "GET", !rotated, state.identity?.refreshToken != nil else { throw NetworkFailure.unauthorized }
            try await rotateSession()
            guard ticket == epoch else { throw NetworkFailure.pendingPrivacy }
            return try await client.send(request, token: state.identity!.token)
        }
    }

    private func acceptUser(_ response: APIEnvelope) throws {
        guard let user = response.user, user.id == state.identity?.user.id else { throw NetworkFailure.response }
        state.identity?.user = user
        if !user.sharingEnabled {
            state.uploadAllowed = false
            clearSync()
            clearCircle(notice: "共享已关闭，旧圈友已清除；重新共享和参加均须主动同意。")
        }
        try persist()
        authenticated = !isLegacyIdentity && state.identity?.refreshUncertain != true
    }

    private func sessionIdentity(_ response: APIEnvelope, url: URL, started: Date) throws -> NetworkIdentity {
        guard let access = response.token, EmailRules.isToken(access),
              let refresh = response.refreshToken, EmailRules.isToken(refresh), access != refresh,
              response.expiresIn == 900, let user = response.user else { throw NetworkFailure.response }
        if let existing = state.identity, existing.user.id != user.id { throw NetworkFailure.accountMismatch }
        return NetworkIdentity(baseURL: url.absoluteString, token: access, user: user,
                               refreshToken: refresh, accessExpiresAt: started.addingTimeInterval(900), refreshUncertain: false)
    }

    private func rotateSession() async throws {
        guard storageReady, let client, let identity = state.identity, let refresh = identity.refreshToken,
              identity.refreshUncertain != true else { throw NetworkFailure.sessionUncertain }
        // Write the uncertainty barrier BEFORE rotation. A crash/lost response cannot replay
        // a consumed refresh credential or restore yesterday's session on the next launch.
        state.identity?.refreshUncertain = true
        try persist()
        let started = clock()
        do {
            let response = try await client.send(APIRequest(method: "POST", path: "/v1/auth/refresh",
                                                           body: ["refresh_token": refresh]), token: nil)
            state.identity = try sessionIdentity(response, url: ServiceAddress.validated(identity.baseURL), started: started)
            try persist()
            authenticated = true
        } catch {
            authenticated = false
            // Keep new credentials in memory if their Keychain write failed; retry saves them.
            if !storageReady { throw NetworkFailure.storage }
            throw NetworkFailure.sessionUncertain
        }
    }

    @discardableResult
    func emailAction(_ action: EmailAction, address: String, email: String = "", password: String = "",
                     nickname: String = "", proof: String = "") async -> Bool {
        guard !busy, !privacyRunning, storageReady else { return false }
        if action == .bind && !isLegacyIdentity { return false }
        if action != .login && (state.privacy != nil || state.logoutPending == true) {
            authMessage = NetworkFailure.pendingPrivacy.localizedDescription; return false
        }
        busy = true
        defer { finish() }
        authMessage = nil
        do {
            let url = try ServiceAddress.validated(state.identity?.baseURL ?? address)
            let api = clientFactory(url)
            let request = try action.request(email: email, password: password, nickname: nickname, proof: proof)
            let bearer = isLegacyIdentity && [.bind, .verify, .reset].contains(action) ? state.identity?.token : nil
            let started = clock()
            let response = try await api.send(request, token: bearer)
            if action == .login {
                let identity = try sessionIdentity(response, url: url, started: started)
                let retained = state.identity != nil
                state.identity = identity
                // A login never enables health sharing or joins a circle. Retain pending
                // privacy/logout intent for same-account recovery; no cross-account merge.
                if !retained { state.uploadAllowed = false }
                client = api
                try persist()
                authenticated = true
                accountEmail = nil
                clearBoard(); clearSync()
                authMessage = "已登录，昵称用于公开展示。运动共享和圈子参与须单独主动同意。"
            } else if action.sendsMail {
                guard response.message != nil else { throw NetworkFailure.response }
                authMessage = "若请求适用于账号，邮件已提交给邮件服务器；请实际查看邮箱。尚未验证成功，也不保证已收件。"
            } else {
                guard response.completed == true else { throw NetworkFailure.response }
                authMessage = action == .verify ? "服务器已确认邮箱验证完成。请使用邮箱和密码登录。" : "服务器已确认完成。请重新登录；密码重置会使旧会话失效。"
                if state.identity != nil {
                    state.uploadAllowed = false
                    defaults.set(true, forKey: Self.uploadStopKey)
                    authenticated = false
                    if !isLegacyIdentity { state.identity?.refreshUncertain = true }
                    clearBoard(); clearSync(); accountEmail = nil
                    try persist()
                }
            }
            return true
        } catch {
            if error is EmailRules.Invalid || error is NicknameRules.ValidationError {
                authMessage = error.localizedDescription
            } else {
                authMessage = (error as? NetworkFailure ?? .transport).localizedDescription
                if (error as? NetworkFailure) == .storage { handle(error) }
            }
            return false
        }
    }

    func loadAccount() async {
        guard !busy, storageReady, !isLegacyIdentity, state.identity != nil, state.logoutPending != true else { return }
        busy = true
        let ticket = epoch, accountTicket = accountReadID
        defer { finish() }
        do {
            let response = try await call(APIRequest(method: "GET", path: "/v1/auth/account"))
            guard ticket == epoch, accountTicket == accountReadID, state.logoutPending != true else { return }
            guard response.verified == true, let email = response.email else { throw NetworkFailure.response }
            accountEmail = email
        } catch { accountEmail = nil; handle(error) }
    }

    func hideAccountEmail() { accountReadID = UUID(); accountEmail = nil; authMessage = nil }

    func logout() async {
        guard storageReady, !isLegacyIdentity, state.identity != nil, !privacyRunning, state.privacy == nil else { return }
        epoch = UUID()
        state.uploadAllowed = false; state.logoutPending = true
        defaults.set(true, forKey: Self.uploadStopKey)
        authenticated = false; accountEmail = nil
        clearBoard(); clearSync()
        do { try persist() } catch { handle(error); return }
        privacyRunning = true
        defer { privacyRunning = false }
        await waitForIdle()
        busy = true
        defer { finish() }
        do {
            guard let client, let identity = state.identity else { throw NetworkFailure.storage }
            // Expired access is permitted for revocation. Do not rotate during logout.
            let result = try await client.send(APIRequest(method: "POST", path: "/v1/auth/logout-all", body: [:]), token: identity.token)
            guard result.completed == true else { throw NetworkFailure.response }
            state = SavedNetworkState(); clientReset()
            try persist()
            message = "服务器已确认退出全部设备会话。共享数据仍保留；可重新登录撤回或删除。"
        } catch {
            handle(error)
            message = "退出尚未确认，本机持续停止上传。请重试；若会话失效，重新登录同一账号后再次退出。"
        }
    }

    private func clientReset() { client = nil; authenticated = false; accountEmail = nil }

    func refresh() async {
        dayChangedIfNeeded()
        guard !busy, !privacyRunning, storageReady, state.identity != nil, state.logoutPending != true else { return }
        if boardUpdatedAt != nil { boardIsStale = true }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            let response = try await call(APIRequest(method: "GET", path: "/v1/me"))
            guard ticket == epoch else { return }
            try acceptUser(response)
            try checkDay(response)
            if isLegacyIdentity {
                clearBoard()
                message = NetworkFailure.emailRequired.localizedDescription
                return
            }
            try await loadPage()
            guard ticket == epoch else { return }
            message = state.privacy == nil ? "已刷新服务器资料和今日榜单。" : NetworkFailure.pendingPrivacy.localizedDescription
        } catch { handle(error) }
    }

    func rename(_ input: String) async {
        guard !busy, !privacyRunning, storageReady, authenticated, state.privacy == nil, state.logoutPending != true else { return }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            let name = try NicknameRules.validate(input)
            let response = try await call(APIRequest(method: "PATCH", path: "/v1/me", body: ["nickname": name]))
            guard ticket == epoch else { return }
            try acceptUser(response)
            try checkDay(response)
            try await loadPage()
            guard ticket == epoch else { return }
            message = "联网昵称已修改。"
        } catch let error as NicknameRules.ValidationError { message = error.localizedDescription }
        catch { handle(error) }
    }

    func consentToShare() async {
        guard !busy, !privacyRunning, storageReady, authenticated, state.privacy == nil, state.logoutPending != true else { return }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            // This function is invoked only by the explicit consent confirmation button.
            state.uploadAllowed = false
            defaults.set(true, forKey: Self.uploadStopKey)
            try persist()
            let profile = try await call(APIRequest(method: "GET", path: "/v1/me"))
            guard ticket == epoch else { return }
            try acceptUser(profile)
            try checkDay(profile)
            let response = try await call(APIRequest(method: "PUT", path: "/v1/me/sharing", body: [
                "enabled": true, "expected_revision": state.identity!.user.consentRevision]))
            guard ticket == epoch, state.privacy == nil else { return }
            try acceptUser(response)
            try checkDay(response)
            guard response.user?.sharingEnabled == true else { throw NetworkFailure.response }
            state.uploadAllowed = true
            try persist()
            defaults.set(false, forKey: Self.uploadStopKey)
            clearBoard()
            message = "已同意公开。点击读取并同步后才上传当日运动汇总。圈子仍需单独主动同意。"
        } catch { handle(error) }
    }

    func sync(local: LocalAppModel) async {
        dayChangedIfNeeded()
        guard !busy, !privacyRunning, canUpload else { return }
        busy = true
        let ticket = epoch
        defer { finish() }
        // Keep the last acknowledged snapshot/time when a later attempt fails.
        // The view labels it as a previous result, never as this attempt's success.
        if syncedAt != nil { syncIsStale = true }
        var submitted = false
        var acknowledged = false
        do {
            let profile = try await call(APIRequest(method: "GET", path: "/v1/me"))
            guard ticket == epoch else { return }
            try acceptUser(profile)
            try checkDay(profile)
            guard canUpload else { throw NetworkFailure.consentChanged }
            await local.activate()
            guard ticket == epoch, canUpload else { return }
            guard local.phase == .data, let current = local.snapshot,
                  current.day.date == profile.date, current.day.contains(clock()) else { throw NetworkFailure.localData }
            // An accepted snapshot may move us to another band. Hide the old members
            // before sending, including when the upload result is lost.
            let previousCircle = circle
            let target = try CircleChannel.expected(day: current.day, steps: current.progress.steps)
            clearCircle(preservingSuccess: true, notice: "正在同步今日步数，旧圈友已清除；服务器确认后按每1000步区间匹配。")
            submitted = true
            let response = try await call(APIRequest(method: "PUT", path: "/v1/me/steps", body: [
                "date": current.day.date, "steps": current.progress.steps,
                "expected_revision": state.identity!.user.consentRevision]))
            guard ticket == epoch, canUpload else { return }
            try checkDay(response)
            guard response.consentRevision == state.identity?.user.consentRevision,
                  let progress = response.progress, progress.synced,
                  progress.steps == current.progress.steps, progress.floor == current.progress.floor,
                  progress.remainingSteps == current.progress.remainingSteps else { throw NetworkFailure.response }
            syncedDate = response.date; syncedSteps = progress.steps
            syncedAt = clock(); syncIsStale = false
            acknowledged = true
            let notice = previousCircle.map { previous in
                previous != target
                    ? "今日步数从\(previous.minSteps)–\(previous.maxSteps)步跨入\(target.minSteps)–\(target.maxSteps)步，已自动迁圈；刷新后显示新圈友。"
                    : "今日步数已同步，仍在\(target.minSteps)–\(target.maxSteps)步区间；刷新后确认圈友。"
            } ?? "今日步数已同步；已参加者按每1000步区间自动匹配，未参加者不会自动加入。"
            clearBoard(preservingSuccess: true, circleNotice: notice)
            try await loadPage()
            guard ticket == epoch else { return }
            message = "当日累计快照同步成功，重复提交不会相加。"
        } catch {
            if ticket == epoch, submitted, !acknowledged {
                circleNotice = "本次上传结果未确认，已隐藏旧圈友。可刷新查看服务器当前频道。"
            }
            handle(error)
        }
    }

    func foreground(local: LocalAppModel) async {
        dayChangedIfNeeded()
        markCached()
        await waitForIdle()
        await refresh()
        if canUpload { await sync(local: local) }
        await refreshCircle()
    }

    func dayChangedIfNeeded() {
        if currentDay != ShanghaiDay(containing: clock()) { dayChanged() }
    }

    func joinCircle() async {
        guard !busy, !privacyRunning, canUpload else {
            circleError = "请先在今日楼层榜主动同意共享，再单独同意参加圈子。"; return
        }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            let profile = try await call(APIRequest(method: "GET", path: "/v1/me"))
            guard ticket == epoch, state.privacy == nil else { return }
            try acceptUser(profile); try checkDay(profile)
            guard canUpload else { throw NetworkFailure.consentChanged }
            let response = try await call(APIRequest(method: "PUT", path: "/v1/me/circle-participation",
                body: ["enabled": true, "expected_revision": state.identity!.user.consentRevision]))
            guard ticket == epoch, state.privacy == nil else { return }
            try acceptUser(response); try checkDay(response)
            guard response.participating == true else { throw NetworkFailure.response }
            clearBoard()
            message = "服务器已确认参加圈子；每天按当日步数自动匹配。"
        } catch { handle(error); circleError = error.localizedDescription }
        // Never retry this enable intent automatically, including after a lost response.
    }

    func refreshCircle(more: Bool = false, locate: Bool = false) async {
        dayChangedIfNeeded()
        guard !busy, !privacyRunning, storageReady, authenticated, state.privacy == nil, state.logoutPending != true else { return }
        if more && circleNext == nil { return }
        if circleUpdatedAt != nil { circleIsStale = true }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            var cursor = more ? circleNext : nil
            var locatedChannel: CircleChannel?
            var locatedVersion: String?
            if locate {
                let location = try await call(APIRequest(method: "GET", path: "/v1/circles/current/me",
                    query: [URLQueryItem(name: "limit", value: String(pageSize))]))
                guard ticket == epoch else { return }
                try checkDay(location)
                if location.participating == false { confirmNotParticipating(); return }
                guard location.participating == true, let channel = location.circle,
                      let entry = location.entry, entry.isMe, entry.id == state.identity?.user.id,
                      let version = location.snapshot, location.pageCursor != nil,
                      location.limit == pageSize else { throw NetworkFailure.response }
                try channel.validate(member: entry, day: ShanghaiDay(containing: clock()), userID: state.identity!.user.id)
                locatedChannel = channel; locatedVersion = version
                cursor = location.pageCursor
            }
            var query = [URLQueryItem(name: "limit", value: String(pageSize))]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let response = try await call(APIRequest(method: "GET", path: "/v1/circles/current/members", query: query))
            guard ticket == epoch, state.privacy == nil else { return }
            try checkDay(response)
            guard let participating = response.participating else { throw NetworkFailure.response }
            if !participating { confirmNotParticipating(); return }
            guard let channel = response.circle, channel.date == response.date,
                  let members = response.items, let total = response.total, total >= 1,
                  let version = response.snapshot, response.limit == pageSize,
                  !members.isEmpty, members.count <= pageSize,
                  response.nextCursor == nil || response.nextCursor != cursor else { throw NetworkFailure.response }
            if more && (circle != channel || circleVersion != version) { throw NetworkFailure.pageChanged }
            if locate && (locatedChannel != channel || locatedVersion != version) { throw NetworkFailure.pageChanged }
            let day = ShanghaiDay(containing: clock())
            for member in members {
                try channel.validate(member: member, day: day, userID: state.identity!.user.id)
            }
            let combined = more ? circleMembers + members : members
            guard Set(combined.map(\.id)).count == combined.count, combined.count <= total,
                  !locate || members.contains(where: { $0.isMe }) else { throw NetworkFailure.response }
            if let previous = circle, previous != channel {
                circleNotice = "服务器已按今日步数自动迁圈：\(previous.minSteps)–\(previous.maxSteps)步 → \(channel.minSteps)–\(channel.maxSteps)步，旧圈友已替换。"
            }
            if circle?.id != channel.id { clearChat() }
            circle = channel; circleMembers = combined; circleTotal = total
            circleVersion = version; circleNext = response.nextCursor; circleParticipating = true; circleError = nil
            circleUpdatedAt = clock(); circleIsStale = false
        } catch {
            guard ticket == epoch else { return }
            // Do not present stale membership or yesterday's channel as today's success.
            clearCircle(preservingSuccess: true, notice: circleNotice)
            handle(error); circleError = error.localizedDescription
        }
    }

    private func confirmNotParticipating() {
        clearCircle(notice: "服务器已确认未参加圈子；本机运动不受影响，参加仍须主动同意。")
        circleParticipating = false
        circleUpdatedAt = clock(); circleIsStale = false
    }

    private func loadPage(cursor: String? = nil, append: Bool = false) async throws {
        let ticket = epoch
        var query = [URLQueryItem(name: "limit", value: String(pageSize))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page = try await call(APIRequest(method: "GET", path: "/v1/leaderboard", query: query))
        guard ticket == epoch else { return }
        try checkDay(page)
        guard let items = page.items, let total = page.total, let version = page.snapshot,
              page.limit == pageSize, total >= 0,
              !append || (snapshot == version && boardDate == page.date) else { throw NetworkFailure.pageChanged }
        let combined = append ? entries + items : items
        guard Set(combined.map(\.id)).count == combined.count else { throw NetworkFailure.response }
        entries = combined; self.total = total; snapshot = version
        boardDate = page.date; nextCursor = page.nextCursor
        boardUpdatedAt = clock(); boardIsStale = false
    }

    func loadMore() async {
        dayChangedIfNeeded()
        guard !busy, !privacyRunning, storageReady, let cursor = nextCursor else { return }
        busy = true
        defer { finish() }
        do { try await loadPage(cursor: cursor, append: true) }
        catch { handle(error) }
    }

    func locateMe() async {
        dayChangedIfNeeded()
        guard !busy, !privacyRunning, storageReady, authenticated, state.logoutPending != true else { return }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            var query = [URLQueryItem(name: "limit", value: String(pageSize))]
            if let snapshot { query.append(URLQueryItem(name: "snapshot", value: snapshot)) }
            let location = try await call(APIRequest(method: "GET", path: "/v1/leaderboard/me", query: query))
            guard ticket == epoch else { return }
            try checkDay(location)
            guard let entry = location.entry, entry.isMe, let cursor = location.pageCursor else {
                message = "本人未公开共享，因此不在公开榜单中。"; return
            }
            try await loadPage(cursor: cursor)
            guard ticket == epoch else { return }
            message = "已加载本人所在页；本人以“我”标记。可刷新首页后遍历全部用户。"
        } catch { handle(error) }
    }

    func privacy(_ kind: PrivacyKind, confirmNewAttempt: Bool = false) async {
        guard state.identity != nil, !privacyRunning, state.logoutPending != true else { return }
        if state.privacy == nil || confirmNewAttempt {
            state.privacy = PrivacyIntent(kind: kind)
        }
        guard state.privacy?.kind == kind else { return }
        // Persist the local stop before awaiting any network or in-flight request.
        epoch = UUID()
        state.uploadAllowed = false
        defaults.set(true, forKey: Self.uploadStopKey)
        clearSync(); clearBoard()
        message = "本机已停止上传，隐私操作等待服务器确认。"
        do { try persist() } catch { handle(error); return }
        privacyRunning = true
        defer { privacyRunning = false }
        await waitForIdle()
        busy = true
        defer { finish() }
        do {
            let profile = try await call(APIRequest(method: "GET", path: "/v1/me"))
            try acceptUser(profile)
            if state.privacy?.expectedRevision == nil || kind == .revoke {
                state.privacy?.expectedRevision = state.identity!.user.consentRevision
                try persist()
            }
            let revision = state.privacy!.expectedRevision!
            let request: APIRequest
            switch kind {
            case .revoke: request = APIRequest(method: "PUT", path: "/v1/me/sharing", body: ["enabled": false, "expected_revision": revision])
            case .deleteSteps: request = APIRequest(method: "DELETE", path: "/v1/me/steps", body: ["expected_revision": revision])
            case .deleteAccount: request = APIRequest(method: "DELETE", path: "/v1/me", body: ["expected_revision": revision])
            }
            let response = try await call(request)
            if kind == .deleteAccount {
                guard response.deleted == true else { throw NetworkFailure.response }
                state = SavedNetworkState()
                authenticated = false
                clientReset()
                try persist()
            } else {
                guard response.user?.sharingEnabled == false else { throw NetworkFailure.response }
                if kind == .deleteSteps && response.deletedDays == nil { throw NetworkFailure.response }
                try acceptUser(response)
                state.privacy = nil
                try persist()
            }
            message = kind == .deleteAccount ? "服务器已确认删除账号及关联数据。" : kind == .deleteSteps ? "服务器已确认删除全部日期的共享步数，并关闭共享及圈子参与。" : "服务器已确认撤回共享，并移除公开榜单及圈子资格。"
        } catch {
            handle(error)
            message = "隐私操作尚未确认完成，本机持续停止上传。\(message ?? "") 若删除版本已变化，须重新主动确认删除现存数据；不会自动采用新版本重放删除。"
        }
    }

    func forgetLocalCredential() {
        guard !busy, !privacyRunning, storageReady, state.privacy == nil, state.logoutPending != true else { return }
        epoch = UUID()
        state = SavedNetworkState()
        clientReset()
        clearBoard(); clearSync()
        do { try persist(); message = "已移除此机凭证；这不删除服务端公开数据。已验证邮箱可重新登录；旧匿名身份丢失凭证后不能恢复。" }
        catch { handle(error) }
    }
}

// Messages remain in memory only. Every response is tied to the current day, identity and channel.
extension SocialModel {
    var canChat: Bool { CommunityFeatures.chatEnabled && canUpload && circle != nil && circleParticipating == true && !circleIsStale }

    private func clearChat() {
        chatEpoch = UUID()
        chatMessages = []; chatBefore = nil; chatWatermark = nil
        chatNotice = nil; blockedUsers = []
    }

    private func acceptMessages(_ incoming: [CircleMessage], channel: String) throws {
        let me = state.identity?.user.id
        guard incoming.count <= 50, Set(incoming.map(\.id)).count == incoming.count,
              incoming.allSatisfy({ $0.id > 0 && $0.changeId > 0 && $0.circleId == channel
                  && $0.isMe == ($0.authorId == me) && $0.text.unicodeScalars.count <= 1000
                  && (!$0.deleted || $0.text.isEmpty) }) else { throw NetworkFailure.response }
        var merged = Dictionary(uniqueKeysWithValues: chatMessages.map { ($0.id, $0) })
        for item in incoming { merged[item.id] = item }
        chatMessages = merged.values.sorted { $0.id < $1.id }
        // Bound in-memory history even during a long foreground session.
        if chatMessages.count > 500 { chatMessages.removeFirst(chatMessages.count - 500) }
    }

    func refreshChat(older: Bool = false, reset: Bool = false, background: Bool = false) async {
        dayChangedIfNeeded()
        guard canChat, !busy, let channel = circle?.id else { return }
        if older && chatBefore == nil { return }
        if background { chatPolling = true }
        busy = true
        let ticket = epoch, chatTicket = chatEpoch
        defer {
            if background { chatPolling = false }
            finish()
        }
        do {
            var query = [URLQueryItem(name: "circle_id", value: channel), URLQueryItem(name: "limit", value: "20")]
            if older, let before = chatBefore { query.append(URLQueryItem(name: "before", value: String(before))) }
            else if !reset, let watermark = chatWatermark, watermark > 0 {
                query.append(URLQueryItem(name: "after", value: String(watermark)))
            }
            let response = try await call(APIRequest(method: "GET", path: "/v1/circles/current/messages", query: query))
            guard ticket == epoch, chatTicket == chatEpoch, circle?.id == channel, canChat else { return }
            try checkDay(response)
            guard response.circleId == channel, let items = response.messages,
                  let watermark = response.watermark, watermark >= 0 else { throw NetworkFailure.response }
            if reset { chatMessages = [] }
            try acceptMessages(items, channel: channel)
            if older || reset || chatWatermark == nil { chatBefore = response.nextBefore }
            if !older { chatWatermark = watermark }
            chatNotice = nil
        } catch {
            guard ticket == epoch, chatTicket == chatEpoch else { return }
            handleChat(error)
        }
    }

    private func handleChat(_ error: Error) {
        if (error as? NetworkFailure) == .pageChanged || (error as? NetworkFailure) == .circleRequired {
            clearCircle(notice: "频道或参与状态已变化，请刷新今日圈子后继续交流。")
        }
        handle(error)
        chatNotice = error.localizedDescription
    }

    // A retry uses the same client UUID. A timed-out send never silently duplicates a message.
    func sendChat(text: String, replyTo: Int?, clientID: UUID) async -> Bool {
        if chatPolling { await waitForIdle() }
        dayChangedIfNeeded()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canChat, !busy, !trimmed.isEmpty, trimmed.unicodeScalars.count <= 1000, let channel = circle?.id else { return false }
        busy = true
        let ticket = epoch, chatTicket = chatEpoch
        defer { finish() }
        do {
            let response = try await call(APIRequest(method: "POST", path: "/v1/circles/current/messages",
                body: ["circle_id": channel, "text": trimmed, "reply_to": replyTo.map { $0 as Any } ?? NSNull(), "client_id": clientID.uuidString]))
            guard ticket == epoch, chatTicket == chatEpoch, circle?.id == channel, canChat else { return false }
            try checkDay(response)
            guard response.circleId == channel, let item = response.chatMessage else { throw NetworkFailure.response }
            try acceptMessages([item], channel: channel)
            chatNotice = nil
            return true
        } catch {
            guard ticket == epoch, chatTicket == chatEpoch else { return false }
            handleChat(error)
            return false
        }
    }

    func chatAction(_ action: CircleChatAction) async {
        dayChangedIfNeeded()
        guard canChat, !busy, let channel = circle?.id else { return }
        busy = true
        let ticket = epoch, chatTicket = chatEpoch
        defer { finish() }
        do {
            let request: APIRequest
            switch action {
            case .retract(let id):
                request = APIRequest(method: "DELETE", path: "/v1/circles/current/messages", body: ["circle_id": channel, "message_id": id])
            case .report(let id, let reason):
                request = APIRequest(method: "POST", path: "/v1/circles/current/reports", body: ["circle_id": channel, "message_id": id, "reason": reason])
            case .block(let id, let enabled):
                request = APIRequest(method: "PUT", path: "/v1/circles/current/blocks", body: ["circle_id": channel, "user_id": id, "enabled": enabled])
            case .listBlocks:
                request = APIRequest(method: "GET", path: "/v1/circles/current/blocks", query: [URLQueryItem(name: "circle_id", value: channel)])
            }
            let response = try await call(request)
            guard ticket == epoch, chatTicket == chatEpoch, circle?.id == channel, canChat else { return }
            try checkDay(response)
            guard response.circleId == channel else { throw NetworkFailure.response }
            switch action {
            case .retract:
                guard let item = response.chatMessage, item.deleted else { throw NetworkFailure.response }
                try acceptMessages([item], channel: channel)
                chatNotice = "消息已撤回。"
            case .report:
                guard response.completed == true else { throw NetworkFailure.response }
                chatNotice = "举报已提交。你也可以屏蔽对方。"
            case .block(let id, let enabled):
                guard response.completed == true else { throw NetworkFailure.response }
                chatMessages = []; chatWatermark = nil; chatBefore = nil
                if !enabled { blockedUsers.removeAll { $0.userId == id } }
                chatNotice = enabled ? "已屏蔽，双方后续将互相隐藏圈子消息。" : "已取消屏蔽。"
            case .listBlocks:
                guard let users = response.blockedUsers else { throw NetworkFailure.response }
                blockedUsers = users
            }
        } catch {
            guard ticket == epoch, chatTicket == chatEpoch else { return }
            handleChat(error)
        }
    }
}
