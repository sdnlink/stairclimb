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
        XCTAssertThrowsError(try CircleChannel.expected(day: day, steps: -1))
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
    var fail = false
    func send(_ request: APIRequest, token: String?) async throws -> APIEnvelope {
        requests.append(request)
        if fail { throw NetworkFailure.transport }
        if request.path == "/v1/me" { return NetworkTestData.envelope(["user": NetworkTestData.user(sharing: true, revision: 1)]) }
        if request.method == "PUT" {
            participating = true
            return NetworkTestData.envelope(["user": NetworkTestData.user(sharing: true, revision: 2), "participating": true])
        }
        if request.path.contains("circles") {
            if !participating { return NetworkTestData.envelope(["participating": false]) }
            var member = NetworkTestData.entry()
            member.removeValue(forKey: "rank")
            return NetworkTestData.envelope(["participating": true,
                "circle": ["id": "2026-11-14:0-999", "date": "2026-11-14", "min_steps": 0, "max_steps": 999, "band_steps": 1000],
                "items": [member], "total": 1, "limit": 20, "snapshot": "2026-11-14.2"])
        }
        return NetworkTestData.envelope(["items": [], "total": 0, "limit": 20, "snapshot": "2026-11-14.1"])
    }
}

@MainActor
final class CircleStateTests: XCTestCase {
    func testRefreshNeverJoinsAndExplicitJoinLoadsRealMembers() async throws {
        let api = CircleAPI()
        let store = MemorySecureStore()
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let user = try decoder.decode(ServerUser.self, from: JSONSerialization.data(withJSONObject: NetworkTestData.user(sharing: true, revision: 1)))
        try NetworkVault(store: store).save(SavedNetworkState(identity: NetworkIdentity(baseURL: "https://example.invalid", token: NetworkTestData.token, user: user), uploadAllowed: true))
        let suite = "circle-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SocialModel(vault: NetworkVault(store: store), defaults: defaults, clock: { NetworkTestData.now }, clientFactory: { _ in api })
        await model.refresh()
        await model.refreshCircle()
        XCTAssertEqual(model.circleParticipating, false)
        XCTAssertFalse(api.requests.contains { $0.method == "PUT" })
        await model.joinCircle()
        await model.refreshCircle()
        XCTAssertEqual(model.circleTotal, 1)
        XCTAssertEqual(model.circleMembers.first?.isMe, true)
        XCTAssertEqual(model.circle?.id, "2026-11-14:0-999")
        api.fail = true
        await model.refreshCircle()
        XCTAssertNil(model.circle)
        XCTAssertNotNil(model.circleError)
        api.fail = false
        await model.refreshCircle()
        model.dayChanged()
        XCTAssertNil(model.circle)
        XCTAssertTrue(model.circleMembers.isEmpty)
    }
}
