import XCTest
import CoreMotion
@testable import StairClimb

@MainActor
private final class TestStepReader: StepReadingProviding {
    var isAvailable = true
    var result: Result<StepReading, Error> = .success(.total(101))
    var accessError: Error?
    var requestCount = 0
    var queryDays: [ShanghaiDay] = []
    var pending: [CheckedContinuation<StepReading, Error>] = []
    var suspend = false

    func requestAccess() async throws {
        requestCount += 1
        if let accessError { throw accessError }
    }
    func readSteps(in day: ShanghaiDay) async throws -> StepReading {
        queryDays.append(day)
        if suspend { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return try result.get()
    }
}

@MainActor
final class LocalAppModelTests: XCTestCase {
    private var reader: TestStepReader!
    private var store: MemorySecureStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private var now: Date!
    private var model: LocalAppModel!

    override func setUp() async throws {
        reader = TestStepReader()
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

    func testLegacyHealthPermissionFlagDoesNotAuthorizeMotionReader() async {
        defaults.set(true, forKey: "healthAccessRequestAttempted")
        await model.activate()
        XCTAssertFalse(model.hasRequestedMotionAccess)
        XCTAssertTrue(reader.queryDays.isEmpty)
        XCTAssertEqual(model.phase, .needsRequest)
    }

    func testFirstLaunchDoesNotReadBeforeRequest() async {
        await model.activate()
        XCTAssertEqual(model.phase, .needsRequest)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(reader.queryDays.count, 0)
        await model.requestMotionAccess()
        XCTAssertEqual(reader.requestCount, 1)
        XCTAssertEqual(model.snapshot?.progress.steps, 101)
    }

    func testNoReadableDataDoesNotClaimDenial() async {
        reader.result = .success(.noReadableData)
        await model.requestMotionAccess()
        XCTAssertEqual(model.phase, .noReadableData)
        XCTAssertEqual(model.snapshot?.progress.steps, 0)
        XCTAssertNil(model.readingError)
    }

    func testReadFailurePreservesSameDayLastValueWithoutSuccess() async {
        await model.requestMotionAccess()
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
        await model.requestMotionAccess()
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
        await model.requestMotionAccess()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.snapshot)
    }

    func testRevokedMotionPermissionPreservesCachedStepsWithoutSuccess() async {
        await model.requestMotionAccess()
        reader.result = .failure(MotionStepReader.Failure.denied)
        await model.refresh()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.snapshot?.progress.steps, 101)
        XCTAssertTrue(model.snapshotIsStale)
        XCTAssertTrue(model.readingError?.contains("运动与健身") == true)
        XCTAssertEqual(model.motionDiagnostic, "CoreMotion · denied")
        reader.result = .success(.total(200))
        await model.refresh()
        XCTAssertNil(model.motionDiagnostic)
        XCTAssertNil(model.readingError)
        XCTAssertEqual(model.snapshot?.progress.steps, 200)
    }

    func testRequestFailureHasSafeDiagnosticAndCannotClaimCompletedAuthorization() async {
        reader.accessError = MotionStepReader.Failure.restricted
        await model.requestMotionAccess()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.hasRequestedMotionAccess)
        XCTAssertTrue(reader.queryDays.isEmpty)
        XCTAssertTrue(model.readingError?.contains("限制") == true)
        XCTAssertFalse(model.readingError?.contains("private") == true)
        XCTAssertNotNil(model.motionDiagnostic)
    }

    func testAuthorizationFailureCanRetry() async {
        reader.accessError = MemorySecureStore.Failure.unavailable
        await model.requestMotionAccess()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(reader.queryDays.isEmpty)
        reader.accessError = nil
        await model.requestMotionAccess()
        XCTAssertEqual(model.phase, .data)
    }

    func testUnavailableHealthDoesNotFabricateData() async {
        reader.isAvailable = false
        await model.requestMotionAccess()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(reader.requestCount, 0)
    }

    func testForegroundRefreshUsesNewDataWithoutAnotherPrompt() async {
        await model.requestMotionAccess()
        reader.result = .success(.total(200))
        await model.activate()
        XCTAssertEqual(model.snapshot?.progress.floor, 2)
        XCTAssertEqual(reader.requestCount, 1)
    }

    func testRestartKeepsRequestAttemptButQueriesAgain() async {
        await model.requestMotionAccess()
        reader.result = .success(.total(180))
        let restored = LocalAppModel(reader: reader, vault: IdentityVault(store: store), defaults: defaults, clock: { self.now })
        XCTAssertNil(restored.snapshot)
        await restored.activate()
        XCTAssertEqual(restored.snapshot?.progress.steps, 180)
        XCTAssertEqual(reader.requestCount, 1)
    }

    func testMidnightImmediatelyClearsYesterdayEvenIfNewReadFails() async {
        await model.requestMotionAccess()
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
        await model.requestMotionAccess()
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
        await model.requestMotionAccess()
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
        await model.requestMotionAccess()
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
        await model.requestMotionAccess()
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
        await model.requestMotionAccess()
        XCTAssertEqual(model.phase, .data)
        XCTAssertEqual(model.snapshot?.progress.steps, 101)
        XCTAssertNil(store.data)
    }
}


@MainActor
private final class PedometerStub: PedometerQuerying {
    var isAvailable = true
    var authorizationStatus = CMAuthorizationStatus.authorized
    var queries: [(Date, Date)] = []
    var result: Result<Double?, Error> = .success(123)
    var statusAfterQuery: CMAuthorizationStatus?

    func query(from start: Date, to end: Date) async throws -> Double? {
        queries.append((start, end))
        if let statusAfterQuery { authorizationStatus = statusAfterQuery }
        return try result.get()
    }
}

@MainActor
final class MotionStepReaderTests: XCTestCase {
    func testUsesShanghaiMidnightThroughNowRegardlessOfDeviceTimezone() async throws {
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        let now = NetworkTestData.now
        let day = ShanghaiDay(containing: now)
        let query = PedometerStub()
        let reader = MotionStepReader(pedometer: query, clock: { now })
        let reading = try await reader.readSteps(in: day)
        XCTAssertEqual(reading, .total(123))
        XCTAssertEqual(query.queries.first?.0, ISO8601DateFormatter().date(from: "2026-11-13T16:00:00Z"))
        XCTAssertEqual(query.queries.first?.1, now)
        let repeated = try await reader.readSteps(in: day)
        XCTAssertEqual(repeated, .total(123))
        XCTAssertEqual(query.queries.count, 2)
    }

    func testInitialPermissionProbeIsDiscardedAndDoesNotBecomeTodaysSteps() async throws {
        let query = PedometerStub()
        query.authorizationStatus = .notDetermined
        query.statusAfterQuery = .authorized
        query.result = .success(987)
        let now = NetworkTestData.now
        let reader = MotionStepReader(pedometer: query, clock: { now })
        try await reader.requestAccess()
        XCTAssertEqual(query.queries.count, 1)
        XCTAssertEqual(query.queries[0].0, now.addingTimeInterval(-1))
        XCTAssertEqual(query.queries[0].1, now)
        query.result = .success(100)
        let reading = try await reader.readSteps(in: ShanghaiDay(containing: now))
        XCTAssertEqual(reading, .total(100))
        XCTAssertEqual(query.queries[1].0, ShanghaiDay(containing: now).start)
        // Existing authorization does not trigger another probe/prompt.
        try await reader.requestAccess()
        XCTAssertEqual(query.queries.count, 2)
    }

    func testDeniedRestrictedAndUnavailableNeverIssueASensorQuery() async {
        for status in [CMAuthorizationStatus.denied, .restricted] {
            let query = PedometerStub(); query.authorizationStatus = status
            let reader = MotionStepReader(pedometer: query)
            do { try await reader.requestAccess(); XCTFail("Must not authorize denied/restricted access") }
            catch { XCTAssertTrue(error is MotionStepReader.Failure) }
            do { _ = try await reader.readSteps(in: ShanghaiDay(containing: Date())); XCTFail("Must not query") }
            catch { XCTAssertTrue(error is MotionStepReader.Failure) }
            XCTAssertTrue(query.queries.isEmpty)
        }
        let query = PedometerStub(); query.isAvailable = false
        let reader = MotionStepReader(pedometer: query)
        XCTAssertFalse(reader.isAvailable)
        do { try await reader.requestAccess(); XCTFail("Unavailable device") }
        catch { XCTAssertEqual(error as? MotionStepReader.Failure, .unavailable) }
        XCTAssertTrue(query.queries.isEmpty)
    }

    func testDeniedPermissionAfterPromptIsNotSuccessfulZero() async {
        let query = PedometerStub(); query.authorizationStatus = .notDetermined
        query.statusAfterQuery = .denied; query.result = .success(0)
        let reader = MotionStepReader(pedometer: query)
        do { try await reader.requestAccess(); XCTFail("Denied probe must not succeed") }
        catch { XCTAssertEqual(error as? MotionStepReader.Failure, .denied) }
    }

    func testEmptyZeroAndQueryErrorAreDistinct() async throws {
        let query = PedometerStub(), now = NetworkTestData.now
        let reader = MotionStepReader(pedometer: query, clock: { now })
        query.result = .success(nil)
        let empty = try await reader.readSteps(in: ShanghaiDay(containing: now))
        XCTAssertEqual(empty, .noReadableData)
        query.result = .success(0)
        let zero = try await reader.readSteps(in: ShanghaiDay(containing: now))
        XCTAssertEqual(zero, .total(0))
        query.result = .failure(NSError(domain: CMErrorDomain, code: 42))
        do { _ = try await reader.readSteps(in: ShanghaiDay(containing: now)); XCTFail("Error is not empty data") }
        catch { XCTAssertEqual((error as NSError).domain, CMErrorDomain) }
    }

    func testPermissionRevokedDuringQueryCannotPublishCount() async {
        let query = PedometerStub(); query.statusAfterQuery = .denied
        let now = NetworkTestData.now
        let reader = MotionStepReader(pedometer: query, clock: { now })
        do { _ = try await reader.readSteps(in: ShanghaiDay(containing: now)); XCTFail("Revoked access must fail") }
        catch { XCTAssertEqual(error as? MotionStepReader.Failure, .denied) }
    }

    func testUndeterminedReadDoesNotTriggerPermissionWithoutExplicitAction() async {
        let query = PedometerStub(); query.authorizationStatus = .notDetermined
        let reader = MotionStepReader(pedometer: query)
        do { _ = try await reader.readSteps(in: ShanghaiDay(containing: Date())); XCTFail("Must request first") }
        catch { XCTAssertEqual(error as? MotionStepReader.Failure, .notDetermined) }
        XCTAssertTrue(query.queries.isEmpty)
    }

    func testFutureDayNeverQueriesAndPastDayEndsAtItsMidnight() async throws {
        let query = PedometerStub(), now = NetworkTestData.now
        let reader = MotionStepReader(pedometer: query, clock: { now })
        let tomorrow = ShanghaiDay(containing: now.addingTimeInterval(86400))
        do { _ = try await reader.readSteps(in: tomorrow); XCTFail("Future day must fail") }
        catch { XCTAssertEqual(error as? MotionStepReader.Failure, .invalidInterval) }
        XCTAssertTrue(query.queries.isEmpty)
        let yesterday = ShanghaiDay(containing: now.addingTimeInterval(-86400))
        _ = try await reader.readSteps(in: yesterday)
        XCTAssertEqual(query.queries.first?.1, yesterday.end)
    }

    func testMotionDiagnosticDoesNotExposeRawErrorDetails() {
        let error = NSError(domain: "private device domain", code: 123,
            userInfo: [NSLocalizedDescriptionKey: "private step record"])
        XCTAssertEqual(MotionFailureMessage.diagnostic(for: error), "SystemError · 123")
        XCTAssertFalse(MotionFailureMessage.detail(for: error, requesting: false).contains("private"))
        XCTAssertTrue(MotionFailureMessage.detail(for: MotionStepReader.Failure.denied, requesting: false).contains("运动与健身"))
    }
}
