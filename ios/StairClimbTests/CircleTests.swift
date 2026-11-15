import XCTest
@testable import StairClimb

final class CircleRuleTests: XCTestCase {
    func testSameStepsAnd9991000Boundaries() throws {
        let day = ShanghaiDay(containing: NetworkTestData.now)
        let zero = try CircleChannel.expected(day: day, steps: 0)
        XCTAssertEqual(try CircleChannel.expected(day: day, steps: 999), zero)
        XCTAssertNotEqual(try CircleChannel.expected(day: day, steps: 1000), zero)
        XCTAssertEqual(try CircleChannel.expected(day: day, steps: 101), try CircleChannel.expected(day: day, steps: 101))
        XCTAssertEqual(zero.id, "2026-11-14:0-999")
        XCTAssertEqual(try CircleChannel.expected(day: day, steps: 1000).minSteps, 1000)
        XCTAssertEqual(try CircleChannel.expected(day: day, steps: StepRules.maximumSteps).maxSteps, 1_000_999)
        XCTAssertThrowsError(try CircleChannel.expected(day: day, steps: -1))
        XCTAssertThrowsError(try CircleChannel.expected(day: day, steps: StepRules.maximumSteps + 1))
    }

    func testShanghaiMidnightAcrossDeviceZones() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for zone in ["America/Los_Angeles", "Asia/Tokyo"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let before = ShanghaiDay(containing: ISO8601DateFormatter().date(from: "2026-11-14T15:59:59Z")!)
            let after = ShanghaiDay(containing: ISO8601DateFormatter().date(from: "2026-11-14T16:00:00Z")!)
            XCTAssertNotEqual(try CircleChannel.expected(day: before, steps: 101).id,
                              try CircleChannel.expected(day: after, steps: 0).id)
            XCTAssertEqual(after.date, "2026-11-15")
        }
    }
}

@MainActor
private final class CircleAPI: APIRequesting {
    var requests: [APIRequest] = []
    var participating = false
    var sharing = true
    var revision = 1
    var steps = 999
    var memberCount = 1
    var ownPosition = 1
    var now = NetworkTestData.now
    var failure: NetworkFailure?
    var failAfterReplyPath: String?
    var overrides: [String: Any] = [:]
    var holdPath: String?
    var pending: CheckedContinuation<Void, Never>?

    func envelope(_ fields: [String: Any]) -> APIEnvelope {
        let day = ShanghaiDay(containing: now)
        let formatter = ISO8601DateFormatter()
        return NetworkTestData.envelope(fields.merging([
            "date": day.date, "day_start": formatter.string(from: day.start),
            "day_end": formatter.string(from: day.end)
        ]) { _, new in new })
    }

    func member(_ position: Int) -> [String: Any] {
        var value = NetworkTestData.entry(id: position == ownPosition ? "mock-user" : "peer-\(position)",
                                         isMe: position == ownPosition, steps: steps)
        value.removeValue(forKey: "rank")
        value["position"] = position
        return value
    }

    private func reply(_ request: APIRequest) throws -> APIEnvelope {
        let user = { NetworkTestData.user(sharing: self.sharing, revision: self.revision) }
        if request.path == "/v1/auth/refresh" {
            return envelope(["user": user(), "token": String(repeating: "a", count: 43),
                             "refresh_token": String(repeating: "b", count: 43), "expires_in": 900])
        }
        if request.path == "/v1/me" && request.method == "GET" { return envelope(["user": user()]) }
        if request.path == "/v1/me/sharing" || request.path == "/v1/me/steps" && request.method == "DELETE" {
            sharing = false; participating = false; revision += 1
            return envelope(["user": user(), "deleted_days": 1])
        }
        if request.path == "/v1/me/circle-participation" {
            XCTAssertEqual(request.body?["expected_revision"] as? Int, revision)
            if !participating { revision += 1 }
            participating = true
            return envelope(["user": user(), "participating": true])
        }
        if request.path == "/v1/me/steps" {
            steps = request.body?["steps"] as! Int
            return envelope(["consent_revision": revision, "progress": [
                "steps": steps, "floor": steps / 100, "remaining_steps": 100 - steps % 100, "synced": true]])
        }
        if request.path.contains("circles") {
            if !participating { return envelope(["participating": false]) }
            let day = ShanghaiDay(containing: now)
            let channel = try CircleChannel.expected(day: day, steps: steps)
            let snapshot = "\(day.date).\(revision)"
            let common: [String: Any] = ["participating": true,
                "circle": ["id": channel.id, "date": channel.date, "min_steps": channel.minSteps,
                           "max_steps": channel.maxSteps, "band_steps": channel.bandSteps],
                "total": memberCount, "limit": 20, "snapshot": snapshot]
            if request.path.hasSuffix("/me") {
                return envelope(common.merging(["entry": member(ownPosition),
                    "page_cursor": "page-\((ownPosition - 1) / 20 * 20)"]) { _, new in new })
            }
            let cursor = request.query.first { $0.name == "cursor" }?.value
            let offset = Int(cursor?.split(separator: "-").last ?? "0") ?? 0
            let end = min(offset + 20, memberCount)
            let members = (offset..<end).map { member($0 + 1) }
            var fields = common.merging(["items": members]) { _, new in new }
            if end < memberCount { fields["next_cursor"] = "page-\(end)" }
            fields.merge(overrides) { _, new in new }
            return envelope(fields)
        }
        return envelope(["items": [], "total": 0, "limit": 20, "snapshot": "\(ShanghaiDay(containing: now).date).\(revision)"])
    }

    func send(_ request: APIRequest, token: String?) async throws -> APIEnvelope {
        requests.append(request)
        if let failure { throw failure }
        let response = try reply(request)
        if failAfterReplyPath == request.path { throw NetworkFailure.transport }
        if holdPath == request.path {
            holdPath = nil
            await withCheckedContinuation { pending = $0 }
        }
        return response
    }
}

@MainActor
private final class CircleHealthReader: HealthStepReading {
    var isAvailable = true
    var steps = 1000.0
    var queriedDays: [String] = []
    func requestAccess() async throws {}
    func readSteps(in day: ShanghaiDay) async throws -> HealthReading {
        queriedDays.append(day.date)
        return .total(steps)
    }
}

@MainActor
final class CircleStateTests: XCTestCase {
    private var api: CircleAPI!
    private var store: MemorySecureStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private var model: SocialModel!

    override func setUpWithError() throws {
        api = CircleAPI(); store = MemorySecureStore()
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let user = try decoder.decode(ServerUser.self, from: JSONSerialization.data(withJSONObject: NetworkTestData.user(sharing: true, revision: 1)))
        try NetworkVault(store: store).save(SavedNetworkState(identity: NetworkIdentity(baseURL: "https://example.invalid", token: NetworkTestData.token, user: user, refreshToken: String(repeating: "r", count: 43), accessExpiresAt: NetworkTestData.now.addingTimeInterval(900)), uploadAllowed: true))
        suite = "circle-tests-\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        model = SocialModel(vault: NetworkVault(store: store), defaults: defaults,
                            clock: { self.api.now }, clientFactory: { _ in self.api })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        model = nil; api = nil; store = nil
    }

    private func joined() async {
        await model.refresh()
        await model.joinCircle()
        await model.refreshCircle()
    }

    private func waitUntilHeld() async {
        for _ in 0..<1000 {
            if api.pending != nil { return }
            await Task.yield()
        }
        XCTFail("Mock request did not reach its explicit suspension point")
    }

    private func release() { let pending = api.pending; api.pending = nil; pending?.resume() }

    func testClosedChatNeverSendsEvenForJoinedMember() async {
        await joined()
        XCTAssertNotNil(model.circle)
        XCTAssertFalse(CommunityFeatures.chatEnabled)
        XCTAssertFalse(model.canChat)
        let count = api.requests.count
        await model.refreshChat()
        let sent = await model.sendChat(text: "一起加油", replyTo: nil, clientID: UUID())
        await model.chatAction(.listBlocks)
        XCTAssertFalse(sent)
        XCTAssertEqual(api.requests.count, count)
        XCTAssertTrue(model.chatMessages.isEmpty)
    }

    func testRefreshNeverJoinsAndExplicitJoinLoadsRealMembers() async {
        await model.refresh()
        await model.refreshCircle()
        XCTAssertEqual(model.circleParticipating, false)
        XCTAssertFalse(api.requests.contains { $0.method == "PUT" })
        await model.joinCircle()
        await model.refreshCircle()
        XCTAssertEqual(model.circleTotal, 1)
        XCTAssertEqual(model.circleMembers.first?.isMe, true)
        XCTAssertEqual(model.circle?.id, "2026-11-14:0-999")
    }

    func testOfflineClearsMembershipAndRefreshNeverReplaysEnable() async {
        await joined()
        let successfulRefresh = model.circleUpdatedAt
        api.now.addTimeInterval(30)
        api.failure = .transport
        await model.refreshCircle()
        XCTAssertNil(model.circle)
        XCTAssertNotNil(model.circleError)
        XCTAssertEqual(model.circleUpdatedAt, successfulRefresh)
        XCTAssertTrue(model.circleIsStale)
        XCTAssertTrue(model.circleMembers.isEmpty)
        api.failure = nil
        await model.refreshCircle()
        XCTAssertEqual(api.requests.filter { $0.method == "PUT" }.count, 1)
        XCTAssertNil(model.circleError)
        XCTAssertEqual(model.circleUpdatedAt, api.now)
        XCTAssertFalse(model.circleIsStale)
        model.dayChanged()
        XCTAssertNil(model.circle)
        XCTAssertTrue(model.circleMembers.isEmpty)
        XCTAssertNil(model.circleUpdatedAt)
    }

    func testAllPagesAndNonFirstPageLocation() async {
        api.memberCount = 21; api.ownPosition = 21
        await joined()
        XCTAssertEqual(model.circleMembers.count, 20)
        XCTAssertFalse(model.circleMembers.contains { $0.isMe })
        await model.refreshCircle(more: true)
        XCTAssertEqual(Set(model.circleMembers.map(\.id)).count, 21)
        XCTAssertNil(model.circleNext)
        await model.refreshCircle(locate: true)
        XCTAssertEqual(model.circleMembers.count, 1)
        XCTAssertEqual(model.circleMembers.first?.position, 21)
        XCTAssertEqual(model.circleMembers.first?.isMe, true)
        await model.refreshCircle()
        XCTAssertEqual(model.circleMembers.count, 20)
    }

    func testChangedPageAndMalformedMemberCannotMixChannels() async {
        api.memberCount = 21
        await joined()
        api.revision += 1
        await model.refreshCircle(more: true)
        XCTAssertNil(model.circle)
        XCTAssertTrue(model.circleMembers.isEmpty)
        XCTAssertNotNil(model.circleError)
        api.overrides = ["items": [NetworkTestData.entry(steps: 1000)]]
        await model.refreshCircle()
        XCTAssertNil(model.circle)
        api.overrides = ["items": [NetworkTestData.entry(id: "peer", isMe: true, steps: 999)]]
        await model.refreshCircle()
        XCTAssertNil(model.circle)
        var invalidFloor = api.member(1); invalidFloor["floor"] = 999
        api.overrides = ["items": [invalidFloor]]
        await model.refreshCircle()
        XCTAssertNil(model.circle)
    }

    func testLocationMustActuallyLoadMeFromSameSnapshot() async {
        await joined()
        api.overrides = ["items": [NetworkTestData.entry(id: "peer", isMe: false, steps: 999)]]
        await model.refreshCircle(locate: true)
        XCTAssertNil(model.circle)
        api.overrides = ["snapshot": "2026-11-14.999"]
        await model.refreshCircle(locate: true)
        XCTAssertNil(model.circle)
    }

    func testRepeatedCursorCannotOfferAnEndlessLoadMoreLoop() async {
        api.memberCount = 21
        await joined()
        api.overrides = ["next_cursor": "page-20"]
        await model.refreshCircle(more: true)
        XCTAssertNil(model.circle)
        XCTAssertNotNil(model.circleError)
    }

    func testRevocationWaitsForReadAndLateResponseCannotRestoreMembers() async throws {
        await joined()
        api.holdPath = "/v1/circles/current/members"
        let reading = Task { await model.refreshCircle() }
        await waitUntilHeld()
        let revoke = Task { await model.privacy(.revoke, confirmNewAttempt: true) }
        for _ in 0..<1000 {
            if model.state.privacy != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(model.state.privacy)
        XCTAssertFalse(model.canUpload)
        XCTAssertNil(model.circle)
        XCTAssertFalse(api.requests.contains { $0.path == "/v1/me/sharing" })
        release(); await reading.value; await revoke.value
        XCTAssertNil(model.circle)
        XCTAssertFalse(api.participating)
        XCTAssertNil(model.state.privacy)
        XCTAssertFalse(try NetworkVault(store: store).load().uploadAllowed)
    }

    func testOfflineDeleteStaysPendingAndCannotAutoJoinAfterRestart() async throws {
        await joined()
        api.failure = .transport
        await model.privacy(.deleteSteps, confirmNewAttempt: true)
        XCTAssertNil(model.circle)
        XCTAssertEqual(model.state.privacy?.kind, .deleteSteps)
        let restarted = SocialModel(vault: NetworkVault(store: store), defaults: defaults,
                                   clock: { self.api.now }, clientFactory: { _ in self.api })
        api.failure = nil
        await restarted.refresh(); await restarted.refreshCircle(); await restarted.joinCircle()
        XCTAssertNil(restarted.circle)
        XCTAssertFalse(restarted.canUpload)
        XCTAssertEqual(api.requests.filter { $0.path == "/v1/me/circle-participation" }.count, 1)
        await restarted.privacy(.deleteSteps)
        XCTAssertNil(restarted.state.privacy)
        XCTAssertFalse(api.participating)
    }

    func testDuplicateJoinIsSuppressedAndNeverRetriedByRefresh() async {
        await model.refresh()
        api.holdPath = "/v1/me/circle-participation"
        let joining = Task { await model.joinCircle() }
        await waitUntilHeld()
        await model.joinCircle()
        release(); await joining.value
        await model.refreshCircle()
        XCTAssertEqual(api.requests.filter { $0.path == "/v1/me/circle-participation" }.count, 1)
    }

    func testMidnightInvalidatesHeldResponseAndForegroundReadsBeforeRegrouping() async {
        await joined()
        api.holdPath = "/v1/circles/current/members"
        let oldRead = Task { await model.refreshCircle() }
        await waitUntilHeld()
        api.now = ISO8601DateFormatter().date(from: "2026-11-14T16:00:00Z")!
        model.dayChangedIfNeeded()
        XCTAssertNil(model.circle)
        XCTAssertNil(model.circleUpdatedAt)
        release(); await oldRead.value
        XCTAssertNil(model.circle)
        XCTAssertNil(model.circleUpdatedAt)
        let reader = CircleHealthReader(); reader.steps = 0
        defaults.set(true, forKey: "healthAccessRequestAttempted")
        let local = LocalAppModel(reader: reader, vault: IdentityVault(store: MemorySecureStore()), defaults: defaults,
                                  clock: { self.api.now })
        await model.foreground(local: local)
        XCTAssertEqual(reader.queriedDays, ["2026-11-15"])
        XCTAssertEqual(model.circle?.date, "2026-11-15")
        XCTAssertEqual(model.circle?.minSteps, 0)
        XCTAssertEqual(model.circleUpdatedAt, api.now)
        XCTAssertEqual(api.requests.filter { $0.path == "/v1/me/circle-participation" }.count, 1)
    }

    func testSyncHidesOldCircleBeforeSendingCrossBandSnapshot() async {
        await joined()
        let successfulRefresh = model.circleUpdatedAt
        let reader = CircleHealthReader()
        defaults.set(true, forKey: "healthAccessRequestAttempted")
        let local = LocalAppModel(reader: reader, vault: IdentityVault(store: MemorySecureStore()), defaults: defaults,
                                  clock: { self.api.now })
        api.holdPath = "/v1/me/steps"
        let syncing = Task { await model.sync(local: local) }
        await waitUntilHeld()
        XCTAssertNil(model.circle)
        XCTAssertTrue(model.circleMembers.isEmpty)
        XCTAssertEqual(model.circleUpdatedAt, successfulRefresh)
        XCTAssertTrue(model.circleIsStale)
        XCTAssertTrue(model.circleNotice?.contains("正在同步") == true)
        release(); await syncing.value
        XCTAssertTrue(model.circleNotice?.contains("999步跨入1000–1999步") == true)
        XCTAssertTrue(model.circleNotice?.contains("自动迁圈") == true)
        await model.refreshCircle()
        XCTAssertEqual(model.circle?.minSteps, 1000)
        XCTAssertEqual(model.circleMembers.first?.steps, 1000)
        XCTAssertEqual(reader.queriedDays, ["2026-11-14"])
        XCTAssertEqual(model.circleUpdatedAt, api.now)
        XCTAssertFalse(model.circleIsStale)
    }

    func testBackgroundAndInFlightRefreshKeepTimestampAndMarkCached() async {
        await joined()
        let successfulRefresh = model.circleUpdatedAt
        model.markCached()
        XCTAssertTrue(model.circleIsStale)
        XCTAssertEqual(model.circleUpdatedAt, successfulRefresh)
        api.now.addTimeInterval(30)
        api.holdPath = "/v1/circles/current/members"
        let reading = Task { await model.refreshCircle() }
        await waitUntilHeld()
        XCTAssertTrue(model.circleIsStale)
        XCTAssertEqual(model.circleUpdatedAt, successfulRefresh)
        release(); await reading.value
        XCTAssertFalse(model.circleIsStale)
        XCTAssertEqual(model.circleUpdatedAt, api.now)
    }

    func testExternalMigrationReplacesMembersAndExplainsNewBand() async {
        await joined()
        api.steps = 1000
        api.now.addTimeInterval(30)
        await model.refreshCircle()
        XCTAssertEqual(model.circle?.minSteps, 1000)
        XCTAssertTrue(model.circleMembers.allSatisfy { $0.steps == 1000 })
        XCTAssertTrue(model.circleNotice?.contains("0–999步 → 1000–1999步") == true)
        XCTAssertEqual(model.circleUpdatedAt, api.now)
    }

    func testLostUploadResponseKeepsPreviousSyncTimeWithoutClaimingMigrationSuccess() async {
        await joined()
        let reader = CircleHealthReader(); reader.steps = 999
        defaults.set(true, forKey: "healthAccessRequestAttempted")
        let local = LocalAppModel(reader: reader, vault: IdentityVault(store: MemorySecureStore()), defaults: defaults,
                                  clock: { self.api.now })
        await model.sync(local: local); await model.refreshCircle()
        let previousSync = model.syncedAt, previousRefresh = model.circleUpdatedAt
        api.now.addTimeInterval(30)
        reader.steps = 1000
        api.failAfterReplyPath = "/v1/me/steps"
        await model.sync(local: local)
        XCTAssertEqual(api.steps, 1000) // The server accepted it; its response was lost.
        XCTAssertEqual(model.syncedAt, previousSync)
        XCTAssertEqual(model.syncedSteps, 999)
        XCTAssertTrue(model.syncIsStale)
        XCTAssertEqual(model.circleUpdatedAt, previousRefresh)
        XCTAssertTrue(model.circleIsStale)
        XCTAssertNil(model.circle)
        XCTAssertTrue(model.circleNotice?.contains("上传结果未确认") == true)
        api.failAfterReplyPath = nil
        await model.refreshCircle()
        XCTAssertEqual(model.circle?.minSteps, 1000)
        XCTAssertEqual(model.circleUpdatedAt, api.now)
        XCTAssertFalse(model.circleIsStale)
        XCTAssertEqual(model.syncedAt, previousSync)
    }

    func testMidnightClearsLastSuccessEvenWhenOfflineAlreadyRemovedChannel() async {
        await joined()
        api.failure = .transport
        await model.refreshCircle()
        XCTAssertNil(model.circle)
        XCTAssertNotNil(model.circleUpdatedAt)
        api.now = ISO8601DateFormatter().date(from: "2026-11-14T16:00:00Z")!
        model.dayChangedIfNeeded()
        XCTAssertNil(model.circleUpdatedAt)
        XCTAssertNil(model.boardUpdatedAt)
        XCTAssertFalse(model.circleIsStale)
        XCTAssertTrue(model.circleNotice?.contains("新一天") == true)
        await model.refreshCircle()
        XCTAssertNil(model.circleUpdatedAt)
    }

    func testPendingRevokeAndLogoutRemoveCircleSuccessImmediately() async {
        await joined()
        XCTAssertNotNil(model.circleUpdatedAt)
        api.failure = .transport
        await model.privacy(.revoke)
        XCTAssertNil(model.circleUpdatedAt)
        XCTAssertTrue(model.circleMembers.isEmpty)
        api.failure = nil
        await model.privacy(.revoke)
        // Recreate a separate saved session for the logout path.
        api.participating = true; api.sharing = true
        var saved = try! NetworkVault(store: store).load()
        saved.identity?.user = ServerUser(id: "mock-user", nickname: "小楼", sharingEnabled: true, consentRevision: api.revision)
        saved.uploadAllowed = true
        try! NetworkVault(store: store).save(saved)
        let restored = SocialModel(vault: NetworkVault(store: store), defaults: defaults,
                                   clock: { self.api.now }, clientFactory: { _ in self.api })
        await restored.refresh(); await restored.refreshCircle()
        XCTAssertNotNil(restored.circleUpdatedAt)
        api.failure = .transport
        await restored.logout()
        XCTAssertNil(restored.circleUpdatedAt)
        XCTAssertTrue(restored.circleMembers.isEmpty)
    }
}
