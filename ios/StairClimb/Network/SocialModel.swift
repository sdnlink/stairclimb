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
    @Published private(set) var authenticated = false
    @Published private(set) var circle: CircleChannel?
    @Published private(set) var circleMembers: [LeaderboardEntry] = []
    @Published private(set) var circleTotal = 0
    @Published private(set) var circleNext: String?
    @Published private(set) var circleVersion: String?
    @Published private(set) var circleParticipating: Bool?
    @Published private(set) var circleError: String?

    let pageSize = 20
    private let vault: NetworkVault
    private let defaults: UserDefaults
    private static let uploadStopKey = "networkUploadStopped"
    private let clock: () -> Date
    private let clientFactory: @MainActor (URL) -> any APIRequesting
    private var client: (any APIRequesting)?
    private var epoch = UUID()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var privacyRunning = false
    private var failedInitialLoad = false

    init(vault: NetworkVault, defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         clientFactory: @escaping @MainActor (URL) -> any APIRequesting = { APIClient(baseURL: $0) }) {
        self.vault = vault
        self.defaults = defaults
        self.clock = clock
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

    var canUpload: Bool {
        storageReady && authenticated && state.uploadAllowed && state.privacy == nil
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

    private func clearBoard() {
        entries = []; boardDate = nil; snapshot = nil; nextCursor = nil; total = 0
        boardUpdatedAt = nil; boardIsStale = false
        clearCircle()
    }

    private func clearCircle() {
        circle = nil; circleMembers = []; circleTotal = 0; circleNext = nil
        circleVersion = nil; circleParticipating = nil; circleError = nil
    }

    func dayChanged() {
        epoch = UUID()
        clearBoard()
        syncedDate = nil; syncedSteps = nil
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
        if failure == .unauthorized || failure == .consentChanged {
            defaults.set(true, forKey: Self.uploadStopKey)
            state.uploadAllowed = false
            authenticated = false
            try? persist()
            clearBoard()
        }
        if failure == .pageChanged { clearBoard() }
        if failure == .dayChanged { dayChanged() }
        syncedDate = nil; syncedSteps = nil
        message = failure.localizedDescription
    }

    private func call(_ request: APIRequest) async throws -> APIEnvelope {
        guard storageReady, let client, let identity = state.identity else { throw NetworkFailure.storage }
        return try await client.send(request, token: identity.token)
    }

    private func acceptUser(_ response: APIEnvelope) throws {
        guard let user = response.user, user.id == state.identity?.user.id else { throw NetworkFailure.response }
        state.identity?.user = user
        if !user.sharingEnabled { state.uploadAllowed = false }
        try persist()
        authenticated = true
    }

    func register(address: String, nickname: String) async {
        guard !busy, !privacyRunning, storageReady, state.identity == nil, state.privacy == nil else { return }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            let url = try ServiceAddress.validated(address)
            let name = try NicknameRules.validate(nickname)
            let api = clientFactory(url)
            let response = try await api.send(APIRequest(method: "POST", path: "/v1/users", body: ["nickname": name]), token: nil)
            guard let token = response.token, token.count == 43,
                  let user = response.user, !user.sharingEnabled else { throw NetworkFailure.response }
            // Keep the returned credential in memory if Keychain fails, and retry that save,
            // rather than registering again and losing the only copy of the first token.
            state = SavedNetworkState(identity: NetworkIdentity(baseURL: url.absoluteString, token: token, user: user))
            client = api
            try persist()
            authenticated = true
            message = "联网身份已创建，默认不共享。无需共享也能浏览排行榜。"
            try checkDay(response)
            try await loadPage()
            guard ticket == epoch else { return }
        } catch let error as NicknameRules.ValidationError { message = error.localizedDescription }
        catch { handle(error) }
    }

    func refresh() async {
        guard !busy, !privacyRunning, storageReady, state.identity != nil else { return }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            let response = try await call(APIRequest(method: "GET", path: "/v1/me"))
            guard ticket == epoch else { return }
            try acceptUser(response)
            try checkDay(response)
            clearBoard()
            try await loadPage()
            guard ticket == epoch else { return }
            message = state.privacy == nil ? "已刷新服务器资料和今日榜单。" : NetworkFailure.pendingPrivacy.localizedDescription
        } catch { handle(error) }
    }

    func rename(_ input: String) async {
        guard !busy, !privacyRunning, storageReady, authenticated, state.privacy == nil else { return }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            let name = try NicknameRules.validate(input)
            let response = try await call(APIRequest(method: "PATCH", path: "/v1/me", body: ["nickname": name]))
            guard ticket == epoch else { return }
            try acceptUser(response)
            try checkDay(response)
            clearBoard()
            try await loadPage()
            guard ticket == epoch else { return }
            message = "联网昵称已修改。"
        } catch let error as NicknameRules.ValidationError { message = error.localizedDescription }
        catch { handle(error) }
    }

    func consentToShare() async {
        guard !busy, !privacyRunning, storageReady, authenticated, state.privacy == nil else { return }
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
            message = "已同意公开。点击读取并同步后才上传当日健康汇总。圈子仍需单独主动同意。"
        } catch { handle(error) }
    }

    func sync(local: LocalAppModel) async {
        guard !busy, !privacyRunning, canUpload else { return }
        busy = true
        let ticket = epoch
        defer { finish() }
        syncedDate = nil; syncedSteps = nil
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
            clearBoard()
            try await loadPage()
            guard ticket == epoch else { return }
            message = "当日累计快照同步成功，重复提交不会相加。"
        } catch { handle(error) }
    }

    func foreground(local: LocalAppModel) async {
        dayChangedIfNeeded()
        await waitForIdle()
        await refresh()
        if canUpload { await sync(local: local) }
        await refreshCircle()
    }

    func dayChangedIfNeeded() {
        let today = ShanghaiDay(containing: clock()).date
        if (boardDate != nil && boardDate != today) || (syncedDate != nil && syncedDate != today)
            || (circle != nil && circle?.date != today) { dayChanged() }
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
        guard !busy, !privacyRunning, storageReady, authenticated, state.privacy == nil else { return }
        if more && circleNext == nil { return }
        busy = true
        let ticket = epoch
        defer { finish() }
        do {
            var cursor = more ? circleNext : nil
            if locate {
                let location = try await call(APIRequest(method: "GET", path: "/v1/circles/current/me",
                    query: [URLQueryItem(name: "limit", value: String(pageSize))]))
                guard ticket == epoch else { return }
                try checkDay(location)
                cursor = location.pageCursor
            }
            var query = [URLQueryItem(name: "limit", value: String(pageSize))]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let response = try await call(APIRequest(method: "GET", path: "/v1/circles/current/members", query: query))
            guard ticket == epoch, state.privacy == nil else { return }
            try checkDay(response)
            guard let participating = response.participating else { throw NetworkFailure.response }
            if !participating { clearCircle(); circleParticipating = false; return }
            guard let channel = response.circle, channel.date == response.date,
                  let members = response.items, let total = response.total, total >= 1,
                  let version = response.snapshot, response.limit == pageSize else { throw NetworkFailure.response }
            if more && (circle != channel || circleVersion != version) { throw NetworkFailure.pageChanged }
            let day = ShanghaiDay(containing: clock())
            for member in members {
                guard try CircleChannel.expected(day: day, steps: member.steps) == channel else { throw NetworkFailure.response }
            }
            let combined = more ? circleMembers + members : members
            guard Set(combined.map(\.id)).count == combined.count else { throw NetworkFailure.response }
            circle = channel; circleMembers = combined; circleTotal = total
            circleVersion = version; circleNext = response.nextCursor; circleParticipating = true; circleError = nil
        } catch {
            // Do not present stale membership or yesterday's channel as today's success.
            clearCircle(); handle(error); circleError = error.localizedDescription
        }
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
        guard !busy, !privacyRunning, storageReady, let cursor = nextCursor else { return }
        busy = true
        defer { finish() }
        do { try await loadPage(cursor: cursor, append: true) }
        catch { handle(error) }
    }

    func locateMe() async {
        guard !busy, !privacyRunning, storageReady, authenticated else { return }
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
        guard state.identity != nil, !privacyRunning else { return }
        if state.privacy == nil || confirmNewAttempt {
            state.privacy = PrivacyIntent(kind: kind)
        }
        guard state.privacy?.kind == kind else { return }
        // Persist the local stop before awaiting any network or in-flight request.
        epoch = UUID()
        state.uploadAllowed = false
        defaults.set(true, forKey: Self.uploadStopKey)
        syncedDate = nil; syncedSteps = nil; clearBoard()
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
                client = nil
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
        guard !busy, !privacyRunning, storageReady, state.privacy == nil else { return }
        epoch = UUID()
        state = SavedNetworkState()
        authenticated = false; client = nil
        clearBoard(); syncedDate = nil; syncedSteps = nil
        do { try persist(); message = "已移除此机凭证；这不删除服务端公开数据，且无法找回旧账号。" }
        catch { handle(error) }
    }
}
