import XCTest
@testable import StairClimb

final class EmailRequestTests: XCTestCase {
    func testAllAuthRequestsHaveExactFieldsAndNoSecretsInURL() throws {
        let expected: [EmailAction: Set<String>] = [
            .login: ["email", "password"], .register: ["email", "password", "nickname"],
            .verify: ["token", "password"], .resend: ["email"], .forgot: ["email"],
            .reset: ["token", "password"], .bind: ["email", "password"],
            .independent: ["token", "password", "nickname"]]
        for action in EmailAction.allCases {
            let request = try action.request(email: " A+tag@EXAMPLE.TEST ", password: "  private password  ", nickname: "小楼", proof: NetworkTestData.token)
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/v1/auth/" + action.rawValue)
            XCTAssertTrue(request.query.isEmpty)
            XCTAssertEqual(Set(request.body!.keys), expected[action]!)
            if action.needsEmail { XCTAssertEqual(request.body?["email"] as? String, "a+tag@example.test") }
            if action.needsPassword { XCTAssertEqual(request.body?["password"] as? String, "  private password  ") }
        }
    }
    func testEmailPasswordAndProofBoundaries() throws {
        for email in ["bad", "a..b@example.test", ".a@example.test", "a@-example.test", "a@中文.test", "a@b..test", "a@@example.test"] {
            XCTAssertThrowsError(try EmailRules.email(email))
        }
        for password in ["short", String(repeating: "a", count: 129), "private\npassword"] {
            XCTAssertThrowsError(try EmailRules.password(password))
        }
        XCTAssertNoThrow(try EmailRules.password(String(repeating: "a", count: 12)))
        XCTAssertNoThrow(try EmailRules.password(String(repeating: "a", count: 128)))
        XCTAssertThrowsError(try EmailRules.proof("https://example.test?token=" + NetworkTestData.token))
        XCTAssertThrowsError(try EmailRules.proof(String(repeating: "中", count: 43)))
    }
}

@MainActor
private final class EmailAPI: APIRequesting {
    var requests: [(APIRequest, String?)] = []
    var fail: NetworkFailure?
    var pathFailures: [String: NetworkFailure] = [:]
    var user = NetworkTestData.user()
    var access = String(repeating: "a", count: 43)
    var refresh = String(repeating: "r", count: 43)
    var completed = true
    var suspendRefresh = false
    var suspendLogin = false
    var pending: CheckedContinuation<APIEnvelope, Error>?
    var accountEmail = "private@example.test"
    func session() -> APIEnvelope {
        NetworkTestData.envelope(["user": user, "token": access, "refresh_token": refresh, "expires_in": 900])
    }
    func send(_ request: APIRequest, token: String?) async throws -> APIEnvelope {
        requests.append((request, token))
        if let fail { throw fail }
        if let failure = pathFailures[request.path] { throw failure }
        if request.path == "/v1/auth/login" {
            if suspendLogin { return try await withCheckedThrowingContinuation { pending = $0 } }
            return session()
        }
        if request.path == "/v1/auth/refresh" {
            access = String(repeating: "b", count: 43); refresh = String(repeating: "s", count: 43)
            if suspendRefresh { return try await withCheckedThrowingContinuation { pending = $0 } }
            return session()
        }
        if ["/v1/auth/register", "/v1/auth/resend", "/v1/auth/forgot-password", "/v1/auth/bind"].contains(request.path) {
            return NetworkTestData.envelope(["message": "accepted; not verified"])
        }
        if request.path == "/v1/auth/account" { return NetworkTestData.envelope(["email": accountEmail, "verified": true]) }
        if request.path.hasPrefix("/v1/auth/") { return NetworkTestData.envelope(["completed": completed]) }
        if request.path == "/v1/me" { return NetworkTestData.envelope(["user": user]) }
        return NetworkTestData.envelope(["items": [], "total": 0, "limit": 20, "snapshot": "2026-11-14.1"])
    }
}

@MainActor
final class EmailSessionTests: XCTestCase {
    private var api: EmailAPI!
    private var store: MemorySecureStore!
    private var defaults: UserDefaults!
    private var model: SocialModel!
    private var suite = ""
    private var now = NetworkTestData.now
    override func setUp() async throws {
        suite = "email-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        api = EmailAPI(); store = MemorySecureStore()
        model = makeModel()
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }
    private func makeModel() -> SocialModel {
        SocialModel(vault: NetworkVault(store: store), defaults: defaults, clock: { self.now }, clientFactory: { _ in self.api })
    }
    private func login() async {
        await model.emailAction(.login, address: "https://example.invalid", email: "private@example.test", password: "private password")
    }
    private func waitForPending() async throws {
        for _ in 0..<10_000 { if api.pending != nil { return }; await Task.yield() }
        XCTFail("Expected suspended auth request"); throw NetworkFailure.transport
    }
    func testRegisterAndMailAcceptedDoNotCreateSessionOrConsent() async {
        await model.emailAction(.register, address: "https://example.invalid", email: "private@example.test", password: "private password", nickname: "小楼")
        XCTAssertNil(model.state.identity)
        XCTAssertFalse(model.authenticated)
        XCTAssertFalse(model.canUpload)
        XCTAssertTrue(model.authMessage!.contains("尚未验证成功"))
        XCTAssertFalse(api.requests.contains { $0.0.path == "/v1/users" || $0.0.path == "/v1/me/steps" })
    }
    func testVerifyNeedsCompletedAcknowledgementAndNeverLogsIn() async {
        api.completed = false
        let failed = await model.emailAction(.verify, address: "https://example.invalid", password: "private password", proof: NetworkTestData.token)
        XCTAssertFalse(failed)
        XCTAssertNil(model.state.identity)
        api.completed = true
        let verified = await model.emailAction(.verify, address: "https://example.invalid", password: "private password", proof: NetworkTestData.token)
        XCTAssertTrue(verified)
        XCTAssertFalse(model.authenticated)
        XCTAssertTrue(model.authMessage!.contains("服务器已确认邮箱验证完成"))
    }
    func testLoginStoresOnlySessionAndUserNotEmailPasswordOrProof() async throws {
        await login()
        XCTAssertTrue(model.authenticated)
        XCTAssertFalse(model.canUpload)
        XCTAssertFalse(model.state.uploadAllowed)
        let persisted = String(data: try XCTUnwrap(store.read()), encoding: .utf8)!
        XCTAssertFalse(persisted.contains("private@example.test"))
        XCTAssertFalse(persisted.contains("private password"))
        XCTAssertFalse(persisted.contains("password"))
        XCTAssertFalse(persisted.contains("email"))
        XCTAssertEqual(try NetworkVault(store: store).load().identity?.refreshToken, api.refresh)
        let restored = makeModel()
        await restored.refresh()
        XCTAssertTrue(restored.authenticated)
        XCTAssertEqual(api.requests.filter { $0.0.path == "/v1/auth/login" }.count, 1)
    }
    func testFailedLoginSaveRetainsCredentialForSecureRetry() async throws {
        store.failWrites = true
        await login()
        XCTAssertNotNil(model.state.identity)
        XCTAssertFalse(model.storageReady)
        store.failWrites = false
        model.retrySecureStorage()
        XCTAssertEqual(try NetworkVault(store: store).load().identity?.token, api.access)
        XCTAssertEqual(api.requests.count, 1)
    }
    func testExpirationRotatesOnceAndSavesBothNewCredentials() async throws {
        await login()
        now.addTimeInterval(880)
        await model.refresh()
        XCTAssertEqual(api.requests.filter { $0.0.path == "/v1/auth/refresh" }.count, 1)
        let saved = try NetworkVault(store: store).load().identity!
        XCTAssertEqual(saved.token, api.access)
        XCTAssertEqual(saved.refreshToken, api.refresh)
        XCTAssertEqual(saved.refreshUncertain, false)
        await model.refresh()
        XCTAssertEqual(api.requests.filter { $0.0.path == "/v1/auth/refresh" }.count, 1)
    }
    func testLostRefreshResponsePersistsBarrierAndNeverReplaysAfterRestart() async throws {
        await login()
        now.addTimeInterval(880)
        api.suspendRefresh = true
        let pending = Task { await model.refresh() }
        try await waitForPending()
        XCTAssertEqual(try NetworkVault(store: store).load().identity?.refreshUncertain, true)
        api.pending!.resume(throwing: NetworkFailure.transport); api.pending = nil
        await pending.value
        XCTAssertFalse(model.canUpload)
        let before = api.requests.count
        let restored = makeModel()
        await restored.refresh()
        XCTAssertEqual(api.requests.count, before)
        XCTAssertFalse(restored.authenticated)
    }
    func testDifferentAccountCannotReplacePersistedIdentity() async throws {
        await login()
        api.user["id"] = "someone-else"
        await login()
        XCTAssertEqual(model.state.identity?.user.id, "mock-user")
        XCTAssertEqual(try NetworkVault(store: store).load().identity?.user.id, "mock-user")
        XCTAssertEqual(model.authMessage, NetworkFailure.accountMismatch.localizedDescription)
    }
    func testLegacyRecordSurvivesAndBindingSendsExistingCredentialOnly() async throws {
        let old: [String: Any] = ["identity": ["baseURL": "https://example.invalid", "token": NetworkTestData.token,
            "user": ["id": "mock-user", "nickname": "旧昵称", "sharingEnabled": false, "consentRevision": 4]], "uploadAllowed": false]
        try store.write(JSONSerialization.data(withJSONObject: old))
        model = makeModel()
        XCTAssertTrue(model.isLegacyIdentity)
        await model.emailAction(.bind, address: "https://other.invalid", email: "private@example.test", password: "private password")
        XCTAssertEqual(api.requests.last?.1, NetworkTestData.token)
        XCTAssertNil(api.requests.last?.0.body?["user_id"])
        XCTAssertEqual(model.state.identity?.user.nickname, "旧昵称")
        XCTAssertFalse(model.canUpload)
        await model.emailAction(.verify, address: "", password: "private password", proof: NetworkTestData.token)
        XCTAssertEqual(api.requests.last?.1, NetworkTestData.token)
        await login()
        XCTAssertFalse(model.isLegacyIdentity)
        XCTAssertEqual(model.state.identity?.user.id, "mock-user")
        XCTAssertFalse(model.canUpload)
    }
    func testLogoutOfflineKeepsPendingStopAcrossRestartAndClearsOnlyOnAck() async throws {
        await login()
        api.fail = .transport
        await model.logout()
        XCTAssertTrue(model.state.logoutPending == true)
        XCTAssertFalse(model.canUpload)
        let restored = makeModel()
        let count = api.requests.count
        await restored.refresh()
        XCTAssertEqual(api.requests.count, count)
        XCTAssertNotNil(restored.state.identity)
        api.fail = nil
        api.completed = false
        await restored.logout()
        XCTAssertNotNil(restored.state.identity)
        api.completed = true
        await restored.logout()
        XCTAssertNil(restored.state.identity)
        XCTAssertNil(try NetworkVault(store: store).load().identity)
    }
    func testLogoutWaitsForRotationAndRevokesNewAccessWithoutResumingUploads() async throws {
        await login(); now.addTimeInterval(880); api.suspendRefresh = true
        let refresh = Task { await model.refresh() }
        try await waitForPending()
        let logout = Task { await model.logout() }
        for _ in 0..<10_000 { if model.state.logoutPending == true { break }; await Task.yield() }
        XCTAssertFalse(model.canUpload)
        api.pending!.resume(returning: api.session()); api.pending = nil
        await refresh.value; await logout.value
        XCTAssertEqual(api.requests.last?.0.path, "/v1/auth/logout-all")
        XCTAssertEqual(api.requests.last?.1, api.access)
        XCTAssertNil(model.state.identity)
    }
    func testAccountEmailOnlyInMemoryAndHiddenWhenSettingsClose() async throws {
        await login(); await model.loadAccount()
        XCTAssertEqual(model.accountEmail, "private@example.test")
        XCTAssertFalse(String(data: try XCTUnwrap(store.read()), encoding: .utf8)!.contains("private@example.test"))
        model.hideAccountEmail()
        XCTAssertNil(model.accountEmail)
    }
    func testMailRateLimitAndInvalidProofDoNotShowSuccess() async {
        for error in [NetworkFailure.mailUnavailable, .rateLimited, .invalidCredential, .authentication] {
            api.fail = error
            let result = await model.emailAction(.register, address: "https://example.invalid", email: "private@example.test", password: "private password", nickname: "小楼")
            XCTAssertFalse(result)
            XCTAssertEqual(model.authMessage, error.localizedDescription)
            XCTAssertNil(model.state.identity)
        }
    }
    func testUnauthorizedWriteIsNotReplayedAndDoesNotRotate() async {
        await login()
        api.pathFailures["/v1/me/sharing"] = .unauthorized
        await model.consentToShare()
        XCTAssertEqual(api.requests.filter { $0.0.path == "/v1/me/sharing" }.count, 1)
        XCTAssertFalse(api.requests.contains { $0.0.path == "/v1/auth/refresh" })
        XCTAssertFalse(model.canUpload)
    }
    func testReadNeverRotatesTwiceWhenFreshlyRotatedAccessIsRejected() async {
        await login(); now.addTimeInterval(880)
        api.pathFailures["/v1/me"] = .unauthorized
        await model.refresh()
        XCTAssertEqual(api.requests.filter { $0.0.path == "/v1/auth/refresh" }.count, 1)
        XCTAssertFalse(model.authenticated)
    }
    func testSameAccountLoginPreservesPendingDeletionAndDoesNotEnableSharing() async {
        await login()
        api.fail = .transport
        await model.privacy(.deleteSteps)
        XCTAssertEqual(model.state.privacy?.kind, .deleteSteps)
        api.fail = nil
        await login()
        XCTAssertEqual(model.state.privacy?.kind, .deleteSteps)
        XCTAssertFalse(model.canUpload)
        XCTAssertFalse(model.state.uploadAllowed)
        XCTAssertFalse(api.requests.contains { $0.0.path == "/v1/me/steps" && $0.0.method == "PUT" })
    }
    func testDuplicateAuthSubmissionIsIgnoredWhileLoginInFlight() async throws {
        api.suspendLogin = true
        let request = Task { await self.login() }
        try await waitForPending()
        await login()
        XCTAssertEqual(api.requests.count, 1)
        api.pending!.resume(returning: api.session()); api.pending = nil
        await request.value
        XCTAssertTrue(model.authenticated)
    }
}
