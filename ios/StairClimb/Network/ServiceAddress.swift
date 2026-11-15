import Foundation

enum ServiceAddress {
    // HTTPS is required in Debug and Release, including loopback and LAN development.
    static func validated(_ input: String) throws -> URL {
        guard let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              parts.scheme?.lowercased() == "https",
              var normalized = URLComponents(string: "https://\(parts.percentEncodedHost ?? host)") else {
            throw NetworkFailure.address
        }
        normalized.port = parts.port
        guard let url = normalized.url else { throw NetworkFailure.address }
        return url
    }
}
