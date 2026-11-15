import XCTest
@testable import StairClimb

enum NetworkTestData {
    static let now = ISO8601DateFormatter().date(from: "2026-11-14T10:30:00Z")!
    static let token = String(repeating: "t", count: 43) // Deliberately fake, only used by mocks.
    static func payload(_ fields: [String: Any] = [:]) -> Data {
        var value: [String: Any] = ["date": "2026-11-14", "timezone": "Asia/Shanghai",
            "day_start": "2026-11-14T00:00:00+08:00", "day_end": "2026-11-15T00:00:00+08:00",
            "steps_per_floor": 100, "max_steps": 1_000_000, "circle_band_steps": 1_000]
        fields.forEach { value[$0.key] = $0.value }
        return try! JSONSerialization.data(withJSONObject: value)
    }
    static func envelope(_ fields: [String: Any] = [:]) -> APIEnvelope {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(APIEnvelope.self, from: payload(fields))
    }
    static func user(sharing: Bool = false, revision: Int = 0, nickname: String = "小楼") -> [String: Any] {
        ["id": "mock-user", "nickname": nickname, "sharing_enabled": sharing, "consent_revision": revision]
    }
    static func entry(id: String = "mock-user", isMe: Bool = true, steps: Int = 101) -> [String: Any] {
        ["user_id": id, "nickname": "小楼", "steps": steps, "floor": steps / 100,
         "remaining_steps": 100 - steps % 100, "rank": 1, "position": 1, "is_me": isMe]
    }
}

private final class NetworkURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class NetworkTransportTests: XCTestCase {
    override func tearDown() async throws { NetworkURLProtocol.handler = nil }

    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://example.invalid")!, configuration: configuration)
    }

    func testAddressPolicyRejectsRemoteHTTPAndURLSecrets() throws {
        for input in ["http://example.com", "https://user:password@example.com", "https://example.com?token=bad",
                      "https://example.com/path", "https://example.com#fragment", "ftp://localhost",
                      "http://127.0.bad.0.1", "http://172.32.0.1", "http://[fc::1]", "http://[fd::1]",
                      "http://[2001:4860:4860::8888]", "http://[fe81::1]"] {
            XCTAssertThrowsError(try ServiceAddress.validated(input), input)
        }
        for input in ["http://127.0.0.1:8787", "http://192.168.1.3:8787", "http://computer.local:8787", "http://10.0.0.1",
                      "http://172.16.0.1:8787", "http://172.31.255.254:8787", "http://[::1]:8787",
                      "http://[fc00::1]:8787", "http://[fdff::1]:8787", "http://[fe80::1]:8787"] {
            XCTAssertThrowsError(try ServiceAddress.validated(input), input)
        }
        XCTAssertNoThrow(try ServiceAddress.validated("https://example.com"))
    }

    func testLocalHTTPSAndRootNormalization() throws {
        for value in ["https://127.0.0.1:8443", "https://192.168.1.3:8443", "https://stairclimb.local:8443", "https://[::1]:8443"] {
            XCTAssertNoThrow(try ServiceAddress.validated(value))
        }
        XCTAssertEqual(try ServiceAddress.validated("  https://example.com:443/  ").absoluteString, "https://example.com:443")
    }

    func testDirectClientCannotBypassHTTPSOrSendCredentials() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkURLProtocol.self]
        NetworkURLProtocol.handler = { _ in
            XCTFail("A plaintext request must never reach URLSession")
            return (200, NetworkTestData.payload())
        }
        let plaintext = APIClient(baseURL: URL(string: "http://127.0.0.1:8787")!, configuration: configuration)
        do {
            _ = try await plaintext.send(APIRequest(method: "GET", path: "/v1/me"), token: NetworkTestData.token)
            XCTFail("Expected strict HTTPS rejection")
        } catch { XCTAssertEqual(error as? NetworkFailure, .address) }
        XCTAssertEqual(configuration.tlsMinimumSupportedProtocolVersion, .TLSv12)
    }

    func testRequestUsesAuthorizationHeaderAndAggregateOnlyBody() async throws {
        NetworkURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v1/me/steps")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(NetworkTestData.token)")
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let length = stream.read(&bytes, maxLength: bytes.count)
                data = Data(bytes.prefix(max(0, length)))
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["date", "steps", "expected_revision"])
            return (200, NetworkTestData.payload())
        }
        _ = try await client().send(APIRequest(method: "PUT", path: "/v1/me/steps", body: ["date": "2026-11-14", "steps": 101, "expected_revision": 1]), token: NetworkTestData.token)
    }

    func testPaginationQueryIsEncodedAndCredentialIsNotInURL() async throws {
        NetworkURLProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first(where: { $0.name == "cursor" })?.value, "a+b/=c")
            XCTAssertFalse(request.url!.absoluteString.contains(NetworkTestData.token))
            return (200, NetworkTestData.payload())
        }
        _ = try await client().send(APIRequest(method: "GET", path: "/v1/leaderboard", query: [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "cursor", value: "a+b/=c")]), token: NetworkTestData.token)
    }

    func testHTTPFailuresMapWithoutLeakingServerDetails() async {
        for (status, code, expected) in [(401, "unauthorized", NetworkFailure.unauthorized),
                                        (401, "authentication_failed", .authentication), (400, "invalid_credential", .invalidCredential),
                                        (429, "rate_limited", .rateLimited), (503, "mail_unavailable", .mailUnavailable),
                                        (409, "day_changed", .dayChanged), (409, "leaderboard_changed", .pageChanged),
                                        (409, "consent_changed", .consentChanged), (503, "storage_unavailable", .server("storage_unavailable"))] {
            NetworkURLProtocol.handler = { _ in (status, try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "secret internal detail"]])) }
            do { _ = try await client().send(APIRequest(method: "GET", path: "/v1/me"), token: NetworkTestData.token); XCTFail() }
            catch { XCTAssertEqual(error as? NetworkFailure, expected); XCTAssertFalse(error.localizedDescription.contains("secret")) }
        }
    }

    func testOfflineTimeoutMalformedAndIncompatibleResponsesFail() async {
        for code in [URLError.notConnectedToInternet, .timedOut] {
            NetworkURLProtocol.handler = { _ in throw URLError(code) }
            do { _ = try await client().send(APIRequest(method: "GET", path: "/health"), token: nil); XCTFail() }
            catch { XCTAssertEqual(error as? NetworkFailure, .transport) }
        }
        for data in [Data("not-json".utf8), NetworkTestData.payload(["steps_per_floor": 99]), NetworkTestData.payload(["day_end": "2026-11-16T00:00:00+08:00"])] {
            NetworkURLProtocol.handler = { _ in (200, data) }
            do { _ = try await client().send(APIRequest(method: "GET", path: "/health"), token: nil); XCTFail() }
            catch { XCTAssertEqual(error as? NetworkFailure, .response) }
        }
    }
}

@MainActor
private final class MockSocialAPI: APIRequesting {
    var sharing = true
    var revision = 1
    var nickname = "小楼"
    var calls: [APIRequest] = []
    var fail: NetworkFailure?
    var failPaths: [String: NetworkFailure] = [:]
    var suspendSteps = false
    var pendingStep: CheckedContinuation<APIEnvelope, Error>?
    var page = 0
    func send(_ request: APIRequest, token: String?) async throws -> APIEnvelope {
        calls.append(request)
        if let fail { throw fail }
        if let failure = failPaths[request.path] { throw failure }
        let user = { NetworkTestData.user(sharing: self.sharing, revision: self.revision, nickname: self.nickname) }
        if request.path == "/v1/auth/login" { sharing = false; revision = 0; return NetworkTestData.envelope(["user": user(), "token": NetworkTestData.token, "refresh_token": String(repeating: "r", count: 43), "expires_in": 900]) }
        if request.path == "/v1/auth/logout-all" { return NetworkTestData.envelope(["completed": true]) }
        if request.path == "/v1/me/sharing" {
            sharing = request.body?["enabled"] as! Bool
            revision += 1
            return NetworkTestData.envelope(["user": user()])
        }
        if request.method == "DELETE" {
            guard request.body?["expected_revision"] as? Int == revision else { throw NetworkFailure.consentChanged }
            revision += 1; sharing = false
            return NetworkTestData.envelope(["deleted": true, "deleted_days": 2, "user": user()])
        }
        if request.path == "/v1/me" {
            if request.method == "PATCH" { nickname = request.body?["nickname"] as! String }
            return NetworkTestData.envelope(["user": user()])
        }
        if request.path == "/v1/me/steps" {
            if suspendSteps { return try await withCheckedThrowingContinuation { pendingStep = $0 } }
            let steps = request.body?["steps"] as! Int
            return stepResponse(steps)
        }
        if request.path == "/v1/leaderboard/me" {
            return NetworkTestData.envelope(["entry": NetworkTestData.entry(), "page_cursor": "my-page", "snapshot": "2026-11-14.1", "limit": 20, "total": 21])
        }
        page += 1
        let cursor = request.query.first(where: { $0.name == "cursor" })?.value
        let entry = NetworkTestData.entry(id: cursor == nil ? "first" : "mock-user", isMe: cursor != nil)
        return NetworkTestData.envelope(["items": [entry], "snapshot": "2026-11-14.1", "limit": 20, "total": 21, "next_cursor": cursor == nil ? "next" as Any : NSNull()])
    }
    func stepResponse(_ steps: Int) -> APIEnvelope {
        NetworkTestData.envelope(["consent_revision": revision,
            "progress": ["steps": steps, "floor": steps/100, "remaining_steps": 100-steps%100, "synced": true, "updated_at": "2026-11-14T10:30:00Z"]])
    }
}

@MainActor
private final class NetworkStepReader: StepReadingProviding {
    var isAvailable = true
    var reading: StepReading = .total(101)
    var error: Error?
    func requestAccess() async throws {}
    func readSteps(in day: ShanghaiDay) async throws -> StepReading {
        if let error { throw error }
        return reading
    }
}

@MainActor
final class SocialModelTests: XCTestCase {
    private var api: MockSocialAPI!
    private var store: MemorySecureStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private var model: SocialModel!
    private var local: LocalAppModel!
    private var health: NetworkStepReader!
    private var now = NetworkTestData.now

    override func setUp() async throws {
        suite = "cn.stairclimb.networktests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        api = MockSocialAPI(); store = MemorySecureStore(); health = NetworkStepReader()
        let user = ServerUser(id: "mock-user", nickname: "小楼", sharingEnabled: true, consentRevision: 1)
        try NetworkVault(store: store).save(SavedNetworkState(identity: NetworkIdentity(baseURL: "https://example.invalid", token: NetworkTestData.token, user: user, refreshToken: String(repeating: "r", count: 43), accessExpiresAt: NetworkTestData.now.addingTimeInterval(900)), uploadAllowed: true))
        model = makeModel()
        local = LocalAppModel(reader: health, vault: IdentityVault(store: MemorySecureStore()), defaults: defaults, clock: { self.now })
        await local.requestMotionAccess()
        await model.refresh()
        api.calls.removeAll()
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        local = nil; model = nil
    }
    private func makeModel() -> SocialModel {
        SocialModel(vault: NetworkVault(store: store), defaults: defaults, clock: { self.now }, clientFactory: { _ in self.api })
    }
    private func waitForStep() async throws {
        for _ in 0..<10_000 { if api.pendingStep != nil { return }; await Task.yield() }
        XCTFail("Expected suspended upload")
        throw NetworkFailure.transport
    }

    func testSyncSendsOnlyFreshCumulativeSummaryAndCanRepeat() async {
        await model.sync(local: local)
        await model.sync(local: local)
        let writes = api.calls.filter { $0.path == "/v1/me/steps" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].body?["steps"] as? Int, 101)
        XCTAssertEqual(Set(writes[0].body!.keys), ["date", "steps", "expected_revision"])
        XCTAssertEqual(model.syncedSteps, 101)
    }

    func testNoReadableDataOrHealthFailureDoesNotUploadZeroOrOldValue() async {
        health.reading = .noReadableData
        await model.sync(local: local)
        XCTAssertFalse(api.calls.contains { $0.path == "/v1/me/steps" })
        health.error = NetworkFailure.localData
        await model.sync(local: local)
        XCTAssertNil(model.syncedDate)
        XCTAssertFalse(api.calls.contains { $0.path == "/v1/me/steps" })
    }

    func testRevokeStopsImmediatelyAndIgnoresInFlightSuccess() async throws {
        api.suspendSteps = true
        let upload = Task { await model.sync(local: local) }
        try await waitForStep()
        let revoke = Task { await model.privacy(.revoke) }
        for _ in 0..<10_000 { if model.state.privacy != nil { break }; await Task.yield() }
        XCTAssertFalse(model.canUpload)
        XCTAssertEqual(try NetworkVault(store: store).load().privacy?.kind, .revoke)
        api.pendingStep!.resume(returning: api.stepResponse(101)); api.pendingStep = nil
        await upload.value; await revoke.value
        XCTAssertNil(model.syncedDate)
        XCTAssertFalse(model.state.identity!.user.sharingEnabled)
        XCTAssertNil(model.state.privacy)
    }

    func testLogoutStopsInFlightUploadAndOnlyRevokesAfterItFinishes() async throws {
        api.suspendSteps = true
        let upload = Task { await model.sync(local: local) }
        try await waitForStep()
        let logout = Task { await model.logout() }
        for _ in 0..<10_000 { if model.state.logoutPending == true { break }; await Task.yield() }
        XCTAssertFalse(model.canUpload)
        XCTAssertFalse(api.calls.contains { $0.path == "/v1/auth/logout-all" })
        api.pendingStep!.resume(returning: api.stepResponse(101)); api.pendingStep = nil
        await upload.value; await logout.value
        XCTAssertNil(model.syncedDate)
        XCTAssertNil(model.state.identity)
        XCTAssertEqual(api.calls.last?.path, "/v1/auth/logout-all")
    }

    func testOfflineDeleteRemainsPendingAcrossRestartAndNeverAutoEnables() async throws {
        api.fail = .transport
        await model.privacy(.deleteSteps)
        XCTAssertEqual(model.state.privacy?.kind, .deleteSteps)
        XCTAssertFalse(model.canUpload)
        XCTAssertTrue(model.message!.contains("尚未确认完成"))
        let restored = makeModel()
        XCTAssertEqual(restored.state.privacy?.kind, .deleteSteps)
        api.fail = nil
        await restored.foreground(local: local)
        XCTAssertFalse(api.calls.contains { $0.path == "/v1/me/sharing" && $0.body?["enabled"] as? Bool == true })
        XCTAssertFalse(restored.canUpload)
    }

    func testDeletionVersionConflictDoesNotAdoptNewRevision() async {
        api.fail = .transport
        await model.privacy(.deleteSteps)
        api.fail = nil
        await model.privacy(.deleteSteps)
        XCTAssertNil(model.state.privacy)
        // Simulate a lost response, with the original version retained in a persisted intent.
        var saved = try! NetworkVault(store: store).load()
        saved.privacy = PrivacyIntent(kind: .deleteSteps, expectedRevision: 1)
        try! NetworkVault(store: store).save(saved)
        let restored = makeModel()
        api.revision = 9
        await restored.privacy(.deleteSteps)
        XCTAssertEqual(restored.state.privacy?.expectedRevision, 1)
        XCTAssertEqual(api.calls.last?.body?["expected_revision"] as? Int, 1)
        XCTAssertFalse(restored.canUpload)
        await restored.privacy(.deleteSteps, confirmNewAttempt: true)
        XCTAssertNil(restored.state.privacy)
    }

    func testConsentIsExplicitAndNotReplayedByRefresh() async {
        await model.privacy(.revoke)
        api.calls.removeAll()
        await model.foreground(local: local)
        XCTAssertFalse(model.canUpload)
        XCTAssertFalse(api.calls.contains { $0.method == "PUT" })
        await model.consentToShare()
        XCTAssertTrue(model.canUpload)
        XCTAssertTrue(api.calls.contains { $0.path == "/v1/me/sharing" && $0.body?["enabled"] as? Bool == true })
    }

    func testAuthenticationFailureStopsPersistedUploadWithoutNewRegistration() async {
        api.fail = .unauthorized
        await model.sync(local: local)
        XCTAssertFalse(model.canUpload)
        XCTAssertFalse(try! NetworkVault(store: store).load().uploadAllowed)
        XCTAssertNotNil(model.state.identity)
        XCTAssertFalse(api.calls.contains { $0.path == "/v1/users" })
    }

    func testMidnightClearsSuccessAndRefusesMismatchedServerDate() async {
        await model.sync(local: local)
        now.addTimeInterval(86_400)
        model.dayChangedIfNeeded()
        XCTAssertNil(model.syncedDate)
        XCTAssertNil(model.boardDate)
        api.calls.removeAll()
        await model.sync(local: local)
        XCTAssertFalse(api.calls.contains { $0.path == "/v1/me/steps" })
    }

    func testPaginationLocatesNonFirstPageMeAndInvalidationClearsPages() async {
        XCTAssertEqual(model.entries.first?.id, "first")
        await model.loadMore()
        XCTAssertEqual(model.entries.map(\.id), ["first", "mock-user"])
        await model.locateMe()
        XCTAssertEqual(model.entries.first?.isMe, true)
        await model.refresh()
        api.fail = .pageChanged
        await model.loadMore()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.nextCursor)
    }

    func testNicknameChangesOnlyAfterServerAcknowledgement() async {
        api.fail = .transport
        await model.rename("新名字")
        XCTAssertEqual(model.state.identity?.user.nickname, "小楼")
        api.fail = nil
        await model.rename("新名字")
        XCTAssertEqual(model.state.identity?.user.nickname, "新名字")
    }

    func testAccountDeleteClearsCredentialOnlyAfterAcknowledgement() async throws {
        api.fail = .transport
        await model.privacy(.deleteAccount)
        XCTAssertNotNil(model.state.identity)
        api.fail = nil
        await model.privacy(.deleteAccount)
        XCTAssertNil(model.state.identity)
        XCTAssertNil(try NetworkVault(store: store).load().identity)
    }

    func testPrivacyStopSurvivesKeychainWriteFailure() async {
        store.failWrites = true
        await model.privacy(.revoke)
        XCTAssertFalse(model.canUpload)
        store.failWrites = false
        let restored = makeModel()
        await restored.refresh()
        XCTAssertFalse(restored.canUpload)
    }

    func testFailedLoginSaveRetainsTokenInMemoryForSafeRetry() async throws {
        let empty = MemorySecureStore()
        empty.failWrites = true
        let candidate = SocialModel(vault: NetworkVault(store: empty), defaults: defaults, clock: { self.now }, clientFactory: { _ in self.api })
        await candidate.emailAction(.login, address: "https://example.invalid", email: "login@example.test", password: "private password")
        XCTAssertNotNil(candidate.state.identity)
        XCTAssertFalse(candidate.storageReady)
        empty.failWrites = false
        candidate.retrySecureStorage()
        XCTAssertTrue(candidate.storageReady)
        XCTAssertEqual(try NetworkVault(store: empty).load().identity?.token, NetworkTestData.token)
    }

    func testOfflineBoardRetainsDateAndMarksCacheAsStale() async {
        XCTAssertFalse(model.entries.isEmpty)
        let successfulRefresh = model.boardUpdatedAt
        now.addTimeInterval(60)
        api.fail = .transport
        await model.refresh()
        XCTAssertFalse(model.entries.isEmpty)
        XCTAssertEqual(model.boardDate, "2026-11-14")
        XCTAssertTrue(model.boardIsStale)
        XCTAssertEqual(model.boardUpdatedAt, successfulRefresh)
        api.fail = nil
        await model.refresh()
        XCTAssertEqual(model.boardUpdatedAt, now)
        XCTAssertFalse(model.boardIsStale)
    }

    func testFailedSyncRetainsLastAcknowledgedTimeAndMarksPreviousResult() async {
        await model.sync(local: local)
        let successfulSync = model.syncedAt
        XCTAssertEqual(successfulSync, now)
        XCTAssertFalse(model.syncIsStale)
        now.addTimeInterval(60)
        health.reading = .total(250)
        api.fail = .transport
        await model.sync(local: local)
        XCTAssertEqual(model.syncedAt, successfulSync)
        XCTAssertEqual(model.syncedSteps, 101)
        XCTAssertTrue(model.syncIsStale)
        api.fail = nil
        await model.sync(local: local)
        XCTAssertEqual(model.syncedAt, now)
        XCTAssertEqual(model.syncedSteps, 250)
        XCTAssertFalse(model.syncIsStale)
    }

    func testAcknowledgedSyncRemainsSuccessfulWhenBoardRefreshFails() async {
        let previousBoard = model.boardUpdatedAt
        now.addTimeInterval(60)
        api.failPaths["/v1/leaderboard"] = .transport
        await model.sync(local: local)
        XCTAssertEqual(model.syncedAt, now)
        XCTAssertEqual(model.syncedSteps, 101)
        XCTAssertFalse(model.syncIsStale)
        XCTAssertEqual(model.boardUpdatedAt, previousBoard)
        XCTAssertTrue(model.boardIsStale)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNotNil(model.message)
    }

    func testBackgroundMarksCachesAndPrivacyAndMidnightRemoveSuccessTimes() async {
        await model.sync(local: local)
        model.markCached()
        XCTAssertTrue(model.boardIsStale)
        XCTAssertTrue(model.syncIsStale)
        XCTAssertNotNil(model.syncedAt)
        now.addTimeInterval(86_400)
        model.dayChangedIfNeeded()
        XCTAssertNil(model.syncedAt)
        XCTAssertNil(model.boardUpdatedAt)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.syncIsStale)
        // Explicit privacy clears the same-day success, rather than keeping a
        // visible upload claim while revocation is pending offline.
        now = NetworkTestData.now
        model.dayChangedIfNeeded()
        await model.sync(local: local)
        XCTAssertNotNil(model.syncedAt)
        api.fail = .transport
        await model.privacy(.revoke)
        XCTAssertNil(model.syncedAt)
        XCTAssertNil(model.boardUpdatedAt)
    }

    func testCredentialRestoreDoesNotRequireAnotherRegistration() async {
        let restored = makeModel()
        await restored.refresh()
        XCTAssertTrue(restored.authenticated)
        XCTAssertEqual(restored.state.identity?.user.id, "mock-user")
        XCTAssertFalse(api.calls.contains { $0.path == "/v1/users" })
    }
}
