import Foundation
import Security

// All identity data and future server credentials use Keychain, never UserDefaults.
struct KeychainStore: SecureDataStoring {
    let service: String
    let account: String

    init(service: String = "cn.stairclimb.local-identity", account: String = "installation") {
        self.service = service
        self.account = account
    }

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问安全存储，请解锁设备后重试。不会覆盖原有身份。" }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            let inserted = SecItemAdd(insertion as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw Failure(status: inserted) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }
}
