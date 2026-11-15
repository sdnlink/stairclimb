import Foundation

// Secrets are function inputs only. No form, email or mail proof is Codable/persisted.
enum EmailAction: String, CaseIterable, Identifiable {
    case login, register, verify, resend, forgot = "forgot-password", reset = "reset-password", bind
    case independent = "register-independent"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .login: "登录"
        case .register: "邮箱注册"
        case .verify: "验证邮箱"
        case .resend: "重发验证邮件"
        case .forgot: "忘记密码"
        case .reset: "重置密码"
        case .bind: "绑定旧身份邮箱"
        case .independent: "建立独立账号"
        }
    }
    var needsEmail: Bool { [.login, .register, .resend, .forgot, .bind].contains(self) }
    var needsPassword: Bool { ![.resend, .forgot].contains(self) }
    var needsNickname: Bool { self == .register || self == .independent }
    var needsProof: Bool { [.verify, .reset, .independent].contains(self) }
    var sendsMail: Bool { [.register, .resend, .forgot, .bind].contains(self) }

    func request(email: String, password: String, nickname: String, proof: String) throws -> APIRequest {
        var body: [String: Any] = [:]
        if needsEmail { body["email"] = try EmailRules.email(email) }
        if needsPassword { body["password"] = try EmailRules.password(password) }
        if needsNickname { body["nickname"] = try NicknameRules.validate(nickname) }
        if needsProof { body["token"] = try EmailRules.proof(proof) }
        return APIRequest(method: "POST", path: "/v1/auth/" + rawValue, body: body)
    }
}

enum EmailRules {
    enum Invalid: LocalizedError {
        case email, password, proof
        var errorDescription: String? {
            switch self {
            case .email: "请输入有效邮箱，最多254个ASCII字符；邮箱仅用于账号和找回，不作为公开昵称。"
            case .password: "密码须为12至128个字符，不含控制字符；不自动修剪空格。"
            case .proof: "请输入邮件中的43位一次性凭据，不要输入完整链接。"
            }
        }
    }
    static func email(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
        guard value.utf8.count <= 254, pieces.count == 2 else { throw Invalid.email }
        let local = String(pieces[0]), domain = String(pieces[1])
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.!#$%&'*+/=?^_`{|}~-")
        guard !local.isEmpty, local.utf8.count <= 64, !local.hasPrefix("."), !local.hasSuffix("."),
              !local.contains(".."), local.allSatisfy({ allowed.contains($0) }), domain.contains(".") else { throw Invalid.email }
        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { throw Invalid.email }
        }
        return value
    }
    static func password(_ value: String) throws -> String {
        guard (12...128).contains(value.unicodeScalars.count),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Invalid.password }
        return value
    }
    static func proof(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isToken(value) else { throw Invalid.proof }
        return value
    }
    static func isToken(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
