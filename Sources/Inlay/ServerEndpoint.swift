import Darwin
import Foundation

/// Validate before loading credentials or creating requests. The HTTP exception
/// for Tailscale address ranges requires a connected tailnet configured by the
/// operator; address validation does not attest network routing.
struct ServerEndpoint {
    enum ValidationError: LocalizedError {
        case invalidAddress
        case insecureTransport

        var errorDescription: String? {
            switch self {
            case .invalidAddress:
                "Enter an HTTP or HTTPS server address without credentials, a query, or a fragment."
            case .insecureTransport:
                "Use HTTPS for this server, or HTTP with localhost or a Tailscale IP address."
            }
        }
    }

    let address: String
    let url: URL

    init(_ value: String) throws {
        // Match existing credential account normalization; changing case or
        // default ports here would strand previously stored Keychain entries.
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "\0" }),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = components.url else { throw ValidationError.invalidAddress }
        guard scheme == "https" || Self.permitsHTTP(host: host) else {
            throw ValidationError.insecureTransport
        }
        self.address = address
        self.url = url
    }

    private static func permitsHTTP(host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let octets = withUnsafeBytes(of: ipv4) { Array($0) }
            return octets[0] == 127 || (octets[0] == 100 && (64...127).contains(octets[1]))
        }
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var ipv6 = in6_addr()
        guard literal.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
        let octets = withUnsafeBytes(of: ipv6) { Array($0) }
        return octets == Array(repeating: 0, count: 15) + [1]
            || octets.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
    }
}
