import XCTest
import HealthKit
@testable import StairClimb

@MainActor
private final class TestHealthReader: HealthStepReading {
    var isAvailable = true
    var result: Result<HealthReading, Error> = .success(.total(101))
    var accessError: Error?
    var requestCount = 0
    var queryDays: [ShanghaiDay] = []
    var pending: [CheckedContinuation<HealthReading, Error>] = []
    var suspend = false

    func requestAccess() async throws {
        requestCount += 1
        if let accessError { throw accessError }
    }
    func readSteps(in day: ShanghaiDay) async throws -> HealthReading {
        queryDays.append(day)
        if suspend { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return try result.get()
    }
}

@MainActor
final class LocalAppModelTests: XCTestCase {
    private var reader: TestHealthReader!
    private var store: MemorySecureStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private var now: Date!
    private var model: LocalAppModel!

    override func setUp() async throws {
        reader = TestHealthReader()
        store = MemorySecureStore()
        suite = "cn.stairclimb.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        now = ISO8601DateFormatter().date(from: "2026-11-14T15:59:59Z")!
        model = LocalAppModel(reader: reader, vault: IdentityVault(store: store), defaults: defaults, clock: { self.now })
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        model = nil
    }

    func testFirstLaunchDoesNotReadBeforeRequest() async {
        await model.activate()
        XCTAssertEqual(model.phase, .needsRequest)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(reader.queryDays.count, 0)
        await model.requestHealthAccess()
        XCTAssertEqual(reader.requestCount, 1)
        XCTAssertEqual(model.snapshot?.progress.steps, 101)
    }

    func testNoReadableDataDoesNotClaimDenial() async {
        reader.result = .success(.noReadableData)
        await model.requestHealthAccess()
        XCTAssertEqual(model.phase, .noReadableData)
        XCTAssertEqual(model.snapshot?.progress.steps, 0)
        XCTAssertNil(model.readingError)
    }

    func testReadFailurePreservesSameDayLastValueWithoutSuccess() async {
        await model.requestHealthAccess()
        let successfulRead = model.snapshot?.readAt
        now.addTimeInterval(0.25)
        reader.result = .failure(MemorySecureStore.Failure.unavailable)
        await model.refresh()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.snapshot?.progress.steps, 101)
        XCTAssertNotNil(model.readingError)
        XCTAssertEqual(model.snapshot?.readAt, successfulRead)
        XCTAssertTrue(model.snapshotIsStale)
    }

    func testCachedReadKeepsSuccessTimeUntilNewResultAndClearsAtMidnight() async throws {
        await model.requestHealthAccess()
        let successfulRead = model.snapshot?.readAt
        XCTAssertFalse(model.snapshotIsStale)
        model.markCached()
        XCTAssertTrue(model.snapshotIsStale)
        now.addTimeInterval(0.25)
        reader.suspend = true
        let read = Task { await model.refresh() }
        try await waitForPending(1)
        XCTAssertTrue(model.snapshotIsStale)
        XCTAssertEqual(model.snapshot?.readAt, successfulRead)
        reader.pending.removeFirst().resume(returning: .total(200))
        await read.value
        XCTAssertEqual(model.snapshot?.readAt, now)
        XCTAssertFalse(model.snapshotIsStale)
        now.addTimeInterval(1)
        model.updateDayIfNeeded()
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.snapshotIsStale)
    }

    func testInitialReadFailureIsNotSuccessfulZero() async {
        reader.result = .failure(MemorySecureStore.Failure.unavailable)
        await model.requestHealthAccess()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.snapshot)
    }

    func testHealthFailureExplainsLockedDatabaseAndPreservesRealSteps() async {
        await model.requestHealthAccess()
        reader.result = .failure(NSError(domain: HKErrorDomain,
            code: HKError.Code.errorDatabaseInaccessible.rawValue))
        await model.refresh()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.snapshot?.progress.steps, 101)
        XCTAssertTrue(model.snapshotIsStale)
        XCTAssertTrue(model.readingError?.contains("解锁") == true)
        XCTAssertEqual(model.healthDiagnostic, "\(HKErrorDomain) · \(HKError.Code.errorDatabaseInaccessible.rawValue)")
        reader.result = .success(.total(200))
        await model.refresh()
        XCTAssertNil(model.healthDiagnostic)
        XCTAssertNil(model.readingError)
        XCTAssertEqual(model.snapshot?.progress.steps, 200)
    }

    func testRequestFailureHasSafeDiagnosticAndCannotClaimCompletedAuthorization() async {
        reader.accessError = NSError(domain: HKErrorDomain,
            code: HKError.Code.errorHealthDataRestricted.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "private health query contents"])
        await model.requestHealthAccess()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.hasRequestedHealthAccess)
        XCTAssertTrue(reader.queryDays.isEmpty)
        XCTAssertTrue(model.readingError?.contains("限制") == true)
        XCTAssertFalse(model.readingError?.contains("private") == true)
        XCTAssertNotNil(model.healthDiagnostic)
    }

    func testAuthorizationFailureCanRetry() async {
        reader.accessError = MemorySecureStore.Failure.unavailable
        await model.requestHealthAccess()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(reader.queryDays.isEmpty)
        reader.accessError = nil
        await model.requestHealthAccess()
        XCTAssertEqual(model.phase, .data)
    }

    func testUnavailableHealthDoesNotFabricateData() async {
        reader.isAvailable = false
        await model.requestHealthAccess()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(reader.requestCount, 0)
    }

    func testForegroundRefreshUsesNewDataWithoutAnotherPrompt() async {
        await model.requestHealthAccess()
        reader.result = .success(.total(200))
        await model.activate()
        XCTAssertEqual(model.snapshot?.progress.floor, 2)
        XCTAssertEqual(reader.requestCount, 1)
    }

    func testRestartKeepsRequestAttemptButQueriesAgain() async {
        await model.requestHealthAccess()
        reader.result = .success(.total(180))
        let restored = LocalAppModel(reader: reader, vault: IdentityVault(store: store), defaults: defaults, clock: { self.now })
        XCTAssertNil(restored.snapshot)
        await restored.activate()
        XCTAssertEqual(restored.snapshot?.progress.steps, 180)
        XCTAssertEqual(reader.requestCount, 1)
    }

    func testMidnightImmediatelyClearsYesterdayEvenIfNewReadFails() async {
        await model.requestHealthAccess()
        now.addTimeInterval(1)
        XCTAssertTrue(model.updateDayIfNeeded())
        XCTAssertEqual(model.day.date, "2026-11-15")
        XCTAssertNil(model.snapshot)
        reader.result = .failure(MemorySecureStore.Failure.unavailable)
        await model.activate()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(reader.queryDays.last?.date, "2026-11-15")
    }

    func testOutOfRangeHealthValueIsFailureAndKeepsPreviousValue() async {
        await model.requestHealthAccess()
        reader.result = .success(.total(1_000_001))
        await model.refresh()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.snapshot?.progress.steps, 101)
    }

    private func waitForPending(_ count: Int) async throws {
        for _ in 0..<10_000 {
            if reader.pending.count >= count { return }
            await Task.yield()
        }
        XCTFail("Health query did not reach the expected suspension point")
        throw MemorySecureStore.Failure.unavailable
    }

    func testOverlappingRefreshIsSuppressed() async throws {
        await model.requestHealthAccess()
        reader.suspend = true
        let task = Task { await model.refresh() }
        try await waitForPending(1)
        let before = reader.queryDays.count
        await model.refresh()
        XCTAssertEqual(reader.queryDays.count, before)
        reader.pending.removeFirst().resume(returning: .total(150))
        await task.value
        XCTAssertEqual(model.snapshot?.progress.steps, 150)
    }

    func testLateYesterdayResponseCannotOverwriteToday() async throws {
        await model.requestHealthAccess()
        reader.suspend = true
        let oldTask = Task { await model.refresh() }
        try await waitForPending(1)
        now.addTimeInterval(1)
        let newTask = Task { await model.activate() }
        try await waitForPending(2)
        reader.pending.removeLast().resume(returning: .total(5))
        await newTask.value
        reader.pending.removeFirst().resume(returning: .total(9999))
        await oldTask.value
        XCTAssertEqual(model.snapshot?.progress.steps, 5)
        XCTAssertEqual(model.snapshot?.day.date, "2026-11-15")
    }

    func testQueryFinishingAcrossMidnightTriggersFreshQuery() async throws {
        await model.requestHealthAccess()
        reader.suspend = true
        let task = Task { await model.refresh() }
        try await waitForPending(1)
        now.addTimeInterval(1)
        reader.suspend = false
        reader.result = .success(.total(2))
        reader.pending.removeFirst().resume(returning: .total(9999))
        await task.value
        XCTAssertEqual(model.snapshot?.progress.steps, 2)
        XCTAssertEqual(model.snapshot?.day.date, "2026-11-15")
    }

    func testIdentityPersistenceAndReadFailureBarrier() throws {
        XCTAssertTrue(model.saveNickname("小楼"))
        let originalID = model.identity?.installationID
        let restored = LocalAppModel(reader: reader, vault: IdentityVault(store: store), defaults: defaults, clock: { self.now })
        XCTAssertEqual(restored.identity?.installationID, originalID)
        XCTAssertTrue(restored.saveNickname("新昵称"))
        XCTAssertEqual(restored.identity?.installationID, originalID)
        store.failReads = true
        let locked = LocalAppModel(reader: reader, vault: IdentityVault(store: store), defaults: defaults, clock: { self.now })
        XCTAssertNotNil(locked.identityError)
        XCTAssertFalse(locked.saveNickname("不能替换"))
        store.failReads = false
        locked.reloadIdentity()
        XCTAssertEqual(locked.identity?.installationID, originalID)
    }

    func testNoConsentOrIdentityIsNeededToReadLocalSteps() async {
        XCTAssertNil(model.identity)
        await model.requestHealthAccess()
        XCTAssertEqual(model.phase, .data)
        XCTAssertEqual(model.snapshot?.progress.steps, 101)
        XCTAssertNil(store.data)
    }
}


final class HealthQueryResultTests: XCTestCase {
    func testEmptyStatisticsAndExplicitNoDataAreEmptyRatherThanFailedReads() throws {
        XCTAssertEqual(try HealthStepReader.result(total: nil, error: nil), .noReadableData)
        let empty = NSError(domain: HKErrorDomain, code: HKError.Code.errorNoData.rawValue)
        XCTAssertEqual(try HealthStepReader.result(total: nil, error: empty), .noReadableData)
        XCTAssertEqual(try HealthStepReader.result(total: 0, error: nil), .total(0))
        XCTAssertEqual(try HealthStepReader.result(total: 101, error: nil), .total(101))
    }

    func testDatabaseAndAuthorizationFailuresNeverBecomeEmptyOrZeroSteps() {
        for code in [HKError.Code.errorDatabaseInaccessible, .errorAuthorizationDenied, .errorHealthDataRestricted] {
            let failure = NSError(domain: HKErrorDomain, code: code.rawValue)
            XCTAssertThrowsError(try HealthStepReader.result(total: nil, error: failure))
            XCTAssertThrowsError(try HealthStepReader.result(total: 100, error: failure))
        }
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: HKError.Code.errorNoData.rawValue)
        XCTAssertThrowsError(try HealthStepReader.result(total: nil, error: unrelated))
    }

    func testFailurePresentationDoesNotRevealRawSystemMessageOrUserInfo() {
        let failure = NSError(domain: "private-user-specific-domain", code: 123,
                              userInfo: [NSLocalizedDescriptionKey: "private sample or credential"])
        XCTAssertEqual(HealthFailureMessage.diagnostic(for: failure), "SystemError · 123")
        XCTAssertFalse(HealthFailureMessage.detail(for: failure, requesting: false).contains("private"))
        let notDetermined = NSError(domain: HKErrorDomain,
            code: HKError.Code.errorAuthorizationNotDetermined.rawValue)
        XCTAssertTrue(HealthFailureMessage.detail(for: notDetermined, requesting: false).contains("健康访问"))
    }
}
