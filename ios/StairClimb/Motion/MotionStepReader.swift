import Foundation
import CoreMotion

enum StepReading: Equatable {
    case total(Double)
    case noReadableData
}

@MainActor
protocol StepReadingProviding {
    var isAvailable: Bool { get }
    func requestAccess() async throws
    func readSteps(in day: ShanghaiDay) async throws -> StepReading
}

@MainActor
protocol PedometerQuerying {
    var isAvailable: Bool { get }
    var authorizationStatus: CMAuthorizationStatus { get }
    func query(from start: Date, to end: Date) async throws -> Double?
}

@MainActor
private final class SystemPedometer: PedometerQuerying {
    private let pedometer = CMPedometer()
    var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }
    var authorizationStatus: CMAuthorizationStatus { CMPedometer.authorizationStatus() }

    func query(from start: Date, to end: Date) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data?.numberOfSteps.doubleValue) }
            }
        }
    }
}

@MainActor
final class MotionStepReader: StepReadingProviding {
    private let pedometer: any PedometerQuerying
    private let clock: () -> Date
    var isAvailable: Bool { pedometer.isAvailable }

    enum Failure: Error, Equatable { case unavailable, denied, restricted, notDetermined, invalidInterval }

    init(pedometer: (any PedometerQuerying)? = nil, clock: @escaping () -> Date = Date.init) {
        self.pedometer = pedometer ?? SystemPedometer()
        self.clock = clock
    }

    private func checkAuthorization(allowRequest: Bool = false) throws {
        guard isAvailable else { throw Failure.unavailable }
        switch pedometer.authorizationStatus {
        case .authorized: return
        case .denied: throw Failure.denied
        case .restricted: throw Failure.restricted
        case .notDetermined:
            if !allowRequest { throw Failure.notDetermined }
        @unknown default: throw Failure.notDetermined
        }
    }

    func requestAccess() async throws {
        try checkAuthorization(allowRequest: true)
        if pedometer.authorizationStatus == .authorized { return }
        // Core Motion has no separate authorization-request API. A short query
        // triggers the Motion & Fitness prompt; discard this probe's step count.
        let now = clock()
        do { _ = try await pedometer.query(from: now.addingTimeInterval(-1), to: now) }
        catch { try checkAuthorization(); throw error }
        try checkAuthorization()
    }

    func readSteps(in day: ShanghaiDay) async throws -> StepReading {
        try checkAuthorization()
        // Query an authoritative cumulative count, never add repeated queries.
        // Foreground refresh catches up system history after app suspension.
        let end = min(clock(), day.end)
        guard end >= day.start else { throw Failure.invalidInterval }
        let total: Double?
        do { total = try await pedometer.query(from: day.start, to: end) }
        catch { try checkAuthorization(); throw error }
        try checkAuthorization()
        guard let total else { return .noReadableData }
        return .total(total)
    }
}

enum MotionFailureMessage {
    static func detail(for error: Error, requesting: Bool) -> String {
        if let failure = error as? MotionStepReader.Failure {
            switch failure {
            case .unavailable: return "此设备不支持本机计步，请使用支持运动与健身的 iPhone；模拟器不提供真实步数。"
            case .denied: return "运动与健身权限已关闭。请在系统设置的“隐私与安全性 → 运动与健身”中允许爬楼梯，然后返回重新读取。"
            case .restricted: return "本机运动访问受系统或设备管理策略限制，请检查限制设置或联系设备管理员。"
            case .notDetermined: return "运动与健身授权尚未完成，请点击“开启本机计步”并完成系统授权。"
            case .invalidInterval: return "查询日期与设备时间不一致，请检查日期后重新读取。"
            }
        }
        if error is StepRules.ValidationError { return "本机步数不符合当前规则，本次结果未采用。请稍后重新读取。" }
        return requesting ? "运动访问请求未完成，请查看计步帮助后重试。未将失败视作零步。"
            : "读取本机步数失败，请稍后重试。上次结果仅供参考。"
    }

    static func diagnostic(for error: Error) -> String {
        if let failure = error as? MotionStepReader.Failure {
            switch failure {
            case .unavailable: return "CoreMotion · unavailable"
            case .denied: return "CoreMotion · denied"
            case .restricted: return "CoreMotion · restricted"
            case .notDetermined: return "CoreMotion · notDetermined"
            case .invalidInterval: return "CoreMotion · invalidInterval"
            }
        }
        if error is StepRules.ValidationError { return "CoreMotion · invalidStepTotal" }
        let failure = error as NSError
        let domain = failure.domain == CMErrorDomain ? CMErrorDomain : "SystemError"
        return "\(domain) · \(failure.code)"
    }
}
