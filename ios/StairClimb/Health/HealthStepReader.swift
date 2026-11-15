import Foundation
import HealthKit

enum HealthReading: Equatable {
    case total(Double)
    case noReadableData
}

@MainActor
protocol HealthStepReading {
    var isAvailable: Bool { get }
    func requestAccess() async throws
    func readSteps(in day: ShanghaiDay) async throws -> HealthReading
}

@MainActor
final class HealthStepReader: HealthStepReading {
    private let store = HKHealthStore()
    private let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    enum Failure: Error { case unavailable, requestFailed }

    func requestAccess() async throws {
        guard isAvailable else { throw Failure.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: [stepType]) { completed, error in
                if let error { continuation.resume(throwing: error) }
                else if completed { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: Failure.requestFailed) }
            }
        }
        // Completion says the request finished, not that read access was granted.
        // HealthKit deliberately cannot reveal a user's read refusal.
    }

    // HealthKit can report an empty statistics query as errorNoData. This is
    // different from a failed database read and does not reveal read permission.
    nonisolated static func result(total: Double?, error: Error?) throws -> HealthReading {
        if let error {
            let failure = error as NSError
            if failure.domain == HKErrorDomain && failure.code == HKError.Code.errorNoData.rawValue {
                return .noReadableData
            }
            throw error
        }
        guard let total else { return .noReadableData }
        return .total(total)
    }

    func readSteps(in day: ShanghaiDay) async throws -> HealthReading {
        guard isAvailable else { throw Failure.unavailable }
        let predicate = HKQuery.predicateForSamples(withStart: day.start, end: day.end,
            options: [.strictStartDate, .strictEndDate])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, statistics, error in
                do {
                    let total = statistics?.sumQuantity()?.doubleValue(for: .count())
                    continuation.resume(returning: try Self.result(total: total, error: error))
                } catch { continuation.resume(throwing: error) }
            }
            store.execute(query)
        }
    }
}


// Only known domain/code values are exposed. Never display raw NSError userInfo,
// query contents, sample values, credentials or a stack trace in the product.
enum HealthFailureMessage {
    static func detail(for error: Error, requesting: Bool) -> String {
        if let failure = error as? HealthStepReader.Failure {
            switch failure {
            case .unavailable: return "此设备无法使用 Apple 健康。请在支持健康功能的 iPhone 上重试。"
            case .requestFailed: return "系统健康访问请求未完成，请保持设备解锁并重试。"
            }
        }
        let failure = error as NSError
        if failure.domain == HKErrorDomain {
            switch failure.code {
            case HKError.Code.errorHealthDataUnavailable.rawValue:
                return "此设备的健康数据不可用。请在 iPhone 上打开健康 App，确认可以查看步数。"
            case HKError.Code.errorHealthDataRestricted.rawValue:
                return "此设备的健康访问受到系统或设备管理策略限制，请检查限制设置或联系设备管理员。"
            case HKError.Code.errorDatabaseInaccessible.rawValue:
                return "健康数据暂时无法访问。请解锁 iPhone，回到前台后重新读取。"
            case HKError.Code.errorAuthorizationNotDetermined.rawValue:
                return "健康访问流程尚未完成，请点击“健康访问”重新请求后再读取。"
            case HKError.Code.errorAuthorizationDenied.rawValue:
                return "系统未允许本次健康操作。请检查健康 App 中的步数读取权限；若安装包经过重新签名，还需确认保留 HealthKit 能力。"
            case HKError.Code.errorUserCanceled.rawValue:
                return "本次健康访问流程已取消，可在设备解锁后重新请求。"
            default: break
            }
        }
        if error is StepRules.ValidationError {
            return "健康步数不符合当前规则，本次结果未采用。请稍后重新读取。"
        }
        return requesting ? "健康访问请求未完成，请查看连接帮助后重试。未将失败视作零步。"
            : "读取步数失败，请查看连接帮助后重试。上次结果仅供本机参考。"
    }

    static func diagnostic(for error: Error) -> String {
        if let failure = error as? HealthStepReader.Failure {
            switch failure {
            case .unavailable: return "HealthKit · unavailable"
            case .requestFailed: return "HealthKit · requestIncomplete"
            }
        }
        if error is StepRules.ValidationError { return "HealthKit · invalidStepTotal" }
        let failure = error as NSError
        let domain = failure.domain == HKErrorDomain ? HKErrorDomain : "SystemError"
        return "\(domain) · \(failure.code)"
    }
}
