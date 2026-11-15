import Foundation

struct LocalIdentity: Codable, Equatable {
    let installationID: UUID
    var nickname: String
}

protocol SecureDataStoring {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct IdentityVault {
    let store: any SecureDataStoring

    func load() throws -> LocalIdentity? {
        guard let data = try store.read() else { return nil }
        let identity = try JSONDecoder().decode(LocalIdentity.self, from: data)
        _ = try NicknameRules.validate(identity.nickname)
        return identity
    }

    func save(_ identity: LocalIdentity) throws {
        _ = try NicknameRules.validate(identity.nickname)
        try store.write(JSONEncoder().encode(identity))
    }
}
