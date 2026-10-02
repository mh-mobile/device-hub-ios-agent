import Foundation

/// Who may drive the shown device through the agent HTTP API.
///
/// Security invariant: the API controls a paired device, so a request must
/// come from loopback or the Tailscale ranges (100.64.0.0/10,
/// fd7a:115c:a1e0::/48) *and* carry `Authorization: Bearer <token>`. The
/// custom header also defeats browser CSRF and DNS rebinding, which cannot
/// attach it without knowing the token. Without a configured token the
/// server never starts.
public struct AgentAccessPolicy: Sendable {
    /// Shorter tokens are treated as unset.
    static let minimumTokenLength = 16

    private let token: [UInt8]

    /// Returns `nil`, leaving the API off, when no usable token is configured.
    /// An unexpanded `$(…)` build setting counts as unset.
    public init?(token: String?) {
        guard let token = token?.trimmingCharacters(in: .whitespaces),
              token.count >= Self.minimumTokenLength,
              !token.hasPrefix("$(")
        else {
            return nil
        }
        self.token = Array(token.utf8)
    }

    enum Decision: Equatable {
        case allowed
        case forbiddenSource
        case unauthorized
    }

    /// `sourceAddress` is the peer's raw IPv4 (4 bytes) or IPv6 (16 bytes)
    /// address; anything else is rejected.
    func decide(sourceAddress: [UInt8], authorization: String?) -> Decision {
        guard Self.isTrustedSource(sourceAddress) else {
            return .forbiddenSource
        }
        guard let authorization,
              authorization.count > 7,
              authorization.prefix(7).lowercased() == "bearer ",
              constantTimeEquals(Array(authorization.dropFirst(7).utf8), token)
        else {
            return .unauthorized
        }
        return .allowed
    }

    static func isTrustedSource(_ address: [UInt8]) -> Bool {
        switch address.count {
        case 4:
            return address[0] == 127
                || (address[0] == 100 && address[1] & 0xC0 == 64)
        case 16:
            let loopback = Array(repeating: UInt8(0), count: 15) + [1]
            let mappedPrefix = Array(repeating: UInt8(0), count: 10) + [0xFF, 0xFF]
            if address == loopback {
                return true
            }
            if Array(address.prefix(12)) == mappedPrefix {
                return isTrustedSource(Array(address.suffix(4)))
            }
            return Array(address.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        default:
            return false
        }
    }

    private func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
