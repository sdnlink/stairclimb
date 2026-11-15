import Foundation

enum PrivacyKind: String, Codable { case revoke, deleteSteps, deleteAccount }

struct PrivacyIntent: Codable, Equatable {
    let kind: PrivacyKind
    var expectedRevision: Int?
}

struct NetworkIdentity: Codable {
    let baseURL: String
    var token: String
    var user: ServerUser
    // Optional fields preserve existing anonymous Keychain records for explicit binding.
    var refreshToken: String?
    var accessExpiresAt: Date?
    var refreshUncertain: Bool?
}

struct SavedNetworkState: Codable {
    var identity: NetworkIdentity?
    var uploadAllowed = false
    var privacy: PrivacyIntent?
    var logoutPending: Bool?
}

struct NetworkVault {
    let store: any SecureDataStoring
    func load() throws -> SavedNetworkState {
        guard let data = try store.read() else { return SavedNetworkState() }
        return try JSONDecoder().decode(SavedNetworkState.self, from: data)
    }
    func save(_ state: SavedNetworkState) throws { try store.write(JSONEncoder().encode(state)) }
}
