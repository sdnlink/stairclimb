import Foundation

struct ServerUser: Codable, Equatable {
    let id: String
    let nickname: String
    let sharingEnabled: Bool
    let consentRevision: Int
}

struct ServerProgress: Decodable {
    let steps: Int
    let floor: Int
    let remainingSteps: Int
    let synced: Bool
    let updatedAt: String?
}

struct LeaderboardEntry: Decodable, Identifiable, Equatable {
    let userId: String
    let nickname: String
    let steps: Int
    let floor: Int
    let remainingSteps: Int
    let rank: Int?
    let position: Int
    let isMe: Bool
    var id: String { userId }
}

struct APIEnvelope: Decodable {
    let date: String
    let timezone: String
    let dayStart: String
    let dayEnd: String
    let stepsPerFloor: Int
    let maxSteps: Int
    let circleBandSteps: Int
    let token: String?
    let user: ServerUser?
    let progress: ServerProgress?
    let consentRevision: Int?
    let items: [LeaderboardEntry]?
    let entry: LeaderboardEntry?
    let total: Int?
    let limit: Int?
    let snapshot: String?
    let nextCursor: String?
    let pageCursor: String?
    let deleted: Bool?
    let deletedDays: Int?
    let participating: Bool?
    let circle: CircleChannel?
    let refreshToken: String?
    let expiresIn: Int?
    let completed: Bool?
    let email: String?
    let verified: Bool?
    let message: String?

    let circleId: String?
    let messages: [CircleMessage]?
    let chatMessage: CircleMessage?
    let nextBefore: Int?
    let watermark: Int?
    let hasMore: Bool?
    let blockedUsers: [BlockedCircleUser]?

    private static let isoFormatter = ISO8601DateFormatter()

    func validateRules() throws {
        guard timezone == ShanghaiDay.timeZoneID, stepsPerFloor == StepRules.stepsPerFloor,
              maxSteps == StepRules.maximumSteps, circleBandSteps == StepRules.circleBandSteps,
              let start = Self.isoFormatter.date(from: dayStart),
              let end = Self.isoFormatter.date(from: dayEnd) else { throw NetworkFailure.response }
        let day = ShanghaiDay(containing: start)
        guard day.date == date, day.start == start, day.end == end else { throw NetworkFailure.response }
    }
}

enum NetworkFailure: Error, LocalizedError, Equatable {
    case circleRequired, chatRateLimited, invalidChat, messageUnavailable
    case address, response, transport, unauthorized, dayChanged, pageChanged, consentChanged
    case server(String)
    case localData, storage, pendingPrivacy
    case authentication, invalidCredential, rateLimited, mailUnavailable, emailRequired, sessionUncertain, accountMismatch

    var errorDescription: String? {
        switch self {
        case .circleRequired: "请先主动同意共享并参加今日圈子，再开始交流。"
        case .chatRateLimited: "发送过快，请稍等10秒再发。"
        case .invalidChat: "请输入1至1000字的消息，不支持控制字符。"
        case .messageUnavailable: "消息已撤回、被屏蔽或不属于当前频道，请刷新聊天。"
        case .address: "请输入HTTPS服务根地址（本机和局域网也须HTTPS），不能包含账号、路径、查询或片段。"
        case .response: "服务器返回不兼容的数据或规则，未视作操作成功。"
        case .transport: "网络不可用、超时或连接失败。请检查地址与网络后重试；未视作操作成功。"
        case .unauthorized: "账号凭证已失效。已停止上传，不会自动创建替代账号。"
        case .dayChanged: "上海日期与服务器不一致或已跨日。旧值已清除，请检查设备时间，再重新读取并同步。"
        case .pageChanged: "日期或榜单已变化，旧页已清除。请从首页刷新。"
        case .consentChanged: "共享版本已变化。已停止本机上传，请刷新资料；重新开启仍需主动同意。"
        case .server: "服务暂不可用或请求未被接受，请稍后刷新确认。"
        case .localData: "没有本次成功读取的当日步数。暂无可读数据或读取失败时不上传零值，请先检查运动与健身权限并重试。"
        case .storage: "安全存储未完成。已停止网络操作，请解锁设备后重试安全存储。"
        case .pendingPrivacy: "隐私操作尚待服务器确认，本机已停止上传。请完成或重新确认该操作。"
        case .authentication: "邮箱、密码或验证状态不正确。请检查输入，完成邮箱验证后再登录。"
        case .invalidCredential: "邮件凭据无效、过期或已使用。请重新申请邮件并输入最新凭据。"
        case .rateLimited: "请求过于频繁，请在5分钟后重试。不要重复提交。"
        case .mailUnavailable: "邮件服务未配置或未接受本次邮件。未显示发送成功，请稍后重试或检查服务配置。"
        case .emailRequired: "请先验证邮箱并登录。旧本机身份可在账号页绑定邮箱，运动共享仍需另行同意。"
        case .sessionUncertain: "会话刷新结果未确认，已停止上传且不会重放刷新凭据。请重新登录同一账号。"
        case .accountMismatch: "登录的账号与本机保留身份不同，未替换原账号。请先处理原账号数据和待完成操作。"
        }
    }
}

struct APIRequest {
    let method: String
    let path: String
    var body: [String: Any]? = nil
    var query: [URLQueryItem] = []
}

@MainActor
protocol APIRequesting {
    func send(_ request: APIRequest, token: String?) async throws -> APIEnvelope
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward credentials or replay writes through a redirect.
        completionHandler(nil)
    }
}

@MainActor
final class APIClient: APIRequesting {
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: APIRequest, token: String?) async throws -> APIEnvelope {
        let approvedURL = try ServiceAddress.validated(baseURL.absoluteString)
        var components = URLComponents(url: approvedURL, resolvingAgainstBaseURL: false)!
        components.path = request.path
        components.queryItems = request.query.isEmpty ? nil : request.query
        guard let url = components.url else { throw NetworkFailure.address }
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = request.method
        outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { outgoing.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body = request.body {
            outgoing.httpBody = try JSONSerialization.data(withJSONObject: body)
            outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: outgoing) }
        catch { throw NetworkFailure.transport }
        guard let http = response as? HTTPURLResponse, data.count <= 1_048_576,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true else {
            throw NetworkFailure.response
        }
        if !(200...299).contains(http.statusCode) {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = (json?["error"] as? [String: Any])?["code"] as? String ?? "unknown"
            switch code {
            case "circle_required": throw NetworkFailure.circleRequired
            case "chat_rate_limited": throw NetworkFailure.chatRateLimited
            case "invalid_chat": throw NetworkFailure.invalidChat
            case "message_unavailable", "message_conflict": throw NetworkFailure.messageUnavailable
            case "authentication_failed": throw NetworkFailure.authentication
            case "invalid_credential": throw NetworkFailure.invalidCredential
            case "rate_limited": throw NetworkFailure.rateLimited
            case "mail_unavailable": throw NetworkFailure.mailUnavailable
            case "email_registration_required", "email_verification_required": throw NetworkFailure.emailRequired
            case "day_changed": throw NetworkFailure.dayChanged
            case "leaderboard_changed", "circle_changed": throw NetworkFailure.pageChanged
            case "consent_changed", "sharing_required": throw NetworkFailure.consentChanged
            default:
                if http.statusCode == 401 { throw NetworkFailure.unauthorized }
                throw NetworkFailure.server(code)
            }
        }
        do {
            let result = try Self.decoder.decode(APIEnvelope.self, from: data)
            try result.validateRules()
            return result
        } catch { throw NetworkFailure.response }
    }
}
