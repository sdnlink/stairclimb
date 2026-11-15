import Foundation

enum ServiceAddress {
    static var allowsLocalHTTP: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func validated(_ input: String, allowLocalHTTP: Bool = allowsLocalHTTP) throws -> URL {
        guard let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              let scheme = parts.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && allowLocalHTTP && isLocal(host)),
              var normalized = URLComponents(string: "\(scheme)://\(parts.percentEncodedHost ?? host)") else {
            throw NetworkFailure.address
        }
        normalized.port = parts.port
        guard let url = normalized.url else { throw NetworkFailure.address }
        return url
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host == "[::1]" || host == "::1" { return true }
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if address.contains(":") {
            // A shortened first hextet such as fc::1 means 00fc, outside fc00::/7.
            let first = address.split(separator: ":", omittingEmptySubsequences: false).first ?? ""
            return (first.count == 4 && (first.hasPrefix("fc") || first.hasPrefix("fd")))
                || first == "fe80"
        }
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = segments.compactMap { Int($0) }
        guard segments.count == 4, segments.allSatisfy({ $0.range(of: "^[0-9]{1,3}$", options: .regularExpression) != nil }),
              octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 127 || octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
    }
}
