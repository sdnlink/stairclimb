import Foundation
import Combine

enum ReadingPhase: Equatable {
    case needsRequest, requesting, loading, data, noReadableData, unavailable, failed
}

struct LocalSnapshot: Equatable {
    let day: ShanghaiDay
    let progress: StepProgress
    let readAt: Date
}

@MainActor
final class LocalAppModel: ObservableObject {
    @Published private(set) var identity: LocalIdentity?
    @Published private(set) var identityError: String?
    @Published private(set) var day: ShanghaiDay
    @Published private(set) var snapshot: LocalSnapshot?
    @Published private(set) var phase: ReadingPhase = .needsRequest
    @Published private(set) var readingError: String?
    @Published private(set) var motionDiagnostic: String?
    @Published private(set) var snapshotIsStale = false

    var hasRequestedMotionAccess: Bool { defaults.bool(forKey: Self.attemptedKey) }

    private let reader: any StepReadingProviding
    private let vault: IdentityVault
    private let defaults: UserDefaults
    private let clock: () -> Date
    private var generation = UUID()
    private var requestingAccess = false
    private static let attemptedKey = "motionAccessRequestAttempted"

    init(reader: any StepReadingProviding, vault: IdentityVault,
         defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.vault = vault
        self.defaults = defaults
        self.clock = clock
        day = ShanghaiDay(containing: clock())
        reloadIdentity()
        if !reader.isAvailable { phase = .unavailable }
    }

    func reloadIdentity() {
        do { identity = try vault.load(); identityError = nil }
        catch { identityError = "无法读取本机安全身份。请解锁设备后重试；原身份不会被替换。" }
    }

    @discardableResult
    func saveNickname(_ input: String) -> Bool {
        // A read failure is different from item-not-found: never replace an inaccessible identity.
        guard identityError == nil else { return false }
        do {
            let name = try NicknameRules.validate(input)
            let updated = LocalIdentity(installationID: identity?.installationID ?? UUID(), nickname: name)
            try vault.save(updated)
            identity = updated
            return true
        } catch { return false }
    }

    func activate() async {
        updateDayIfNeeded()
        markCached()
        guard reader.isAvailable else { phase = .unavailable; return }
        guard defaults.bool(forKey: Self.attemptedKey) else { return }
        await refresh()
    }

    func requestMotionAccess() async {
        guard !requestingAccess, phase != .loading else { return }
        updateDayIfNeeded()
        markCached()
        guard reader.isAvailable else { phase = .unavailable; return }
        requestingAccess = true
        phase = .requesting
        readingError = nil
        motionDiagnostic = nil
        defer { requestingAccess = false }
        do {
            try await reader.requestAccess()
            defaults.set(true, forKey: Self.attemptedKey)
            phase = .needsRequest
            await refresh()
        } catch {
            updateDayIfNeeded()
            readingError = MotionFailureMessage.detail(for: error, requesting: true)
            motionDiagnostic = MotionFailureMessage.diagnostic(for: error)
            phase = .failed
        }
    }

    func refresh() async {
        updateDayIfNeeded()
        markCached()
        guard reader.isAvailable else { phase = .unavailable; return }
        guard defaults.bool(forKey: Self.attemptedKey) else { phase = .needsRequest; return }
        guard phase != .loading, phase != .requesting else { return }
        let queriedDay = day
        let ticket = UUID()
        generation = ticket
        phase = .loading
        readingError = nil
        motionDiagnostic = nil
        do {
            let reading = try await reader.readSteps(in: queriedDay)
            guard ticket == generation else { return }
            // A query finishing across midnight cannot become today's value.
            if !queriedDay.contains(clock()) { await activate(); return }
            switch reading {
            case .total(let total):
                snapshot = LocalSnapshot(day: queriedDay, progress: try StepRules.sensorProgress(total: total), readAt: clock())
                phase = .data
            case .noReadableData:
                snapshot = LocalSnapshot(day: queriedDay, progress: try StepRules.progress(steps: 0), readAt: clock())
                phase = .noReadableData
            }
            snapshotIsStale = false
        } catch {
            guard ticket == generation else { return }
            if !queriedDay.contains(clock()) { await activate(); return }
            // Preserve same-day last readable value and label it as old, never fabricate zero.
            readingError = MotionFailureMessage.detail(for: error, requesting: false)
            motionDiagnostic = MotionFailureMessage.diagnostic(for: error)
            phase = .failed
        }
    }

    func markCached() {
        if snapshot != nil { snapshotIsStale = true }
    }

    @discardableResult
    func updateDayIfNeeded() -> Bool {
        let current = ShanghaiDay(containing: clock())
        guard day != current else { return false }
        generation = UUID()
        day = current
        snapshot = nil
        snapshotIsStale = false
        readingError = nil
        motionDiagnostic = nil
        phase = reader.isAvailable ? .needsRequest : .unavailable
        return true
    }
}
