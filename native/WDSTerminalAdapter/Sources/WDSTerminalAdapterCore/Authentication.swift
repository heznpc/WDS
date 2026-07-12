import CryptoKit
import Foundation

public struct TerminalServerAuthenticationHello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let operation: String
    public let nonce: String

    public init(nonce: String) {
        self.protocolVersion = wdsTerminalProtocolVersion
        self.operation = "authenticate_server"
        self.nonce = nonce
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operation
        case nonce
    }
}

public struct TerminalServerAuthenticationProof: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let nonce: String
    public let proofHMACSHA256: String

    public init(
        protocolVersion: Int = wdsTerminalProtocolVersion,
        nonce: String,
        proofHMACSHA256: String
    ) {
        self.protocolVersion = protocolVersion
        self.nonce = nonce
        self.proofHMACSHA256 = proofHMACSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case nonce
        case proofHMACSHA256 = "proof_hmac_sha256"
    }
}

/// Produces the proof WDS.app must return before the client sends any buffer.
/// The token is exactly 32 random bytes encoded as 64 lowercase hex characters.
public func terminalServerAuthenticationProof(
    tokenHex: String,
    nonce: String
) -> String? {
    guard let token = decodeCanonicalHex(tokenHex, expectedByteCount: 32),
          isValidAuthenticationNonce(nonce) else {
        return nil
    }
    let key = SymmetricKey(data: token)
    let message = Data("wds-terminal-server-v1:\(nonce)".utf8)
    return HMAC<SHA256>.authenticationCode(for: message, using: key)
        .map { String(format: "%02x", $0) }
        .joined()
}

public func verifyTerminalServerAuthenticationProof(
    _ proof: TerminalServerAuthenticationProof,
    tokenHex: String,
    nonce: String
) -> Bool {
    guard proof.protocolVersion == wdsTerminalProtocolVersion,
          proof.nonce == nonce,
          let expected = terminalServerAuthenticationProof(tokenHex: tokenHex, nonce: nonce),
          expected.utf8.count == proof.proofHMACSHA256.utf8.count else {
        return false
    }

    var difference: UInt8 = 0
    for (lhs, rhs) in zip(expected.utf8, proof.proofHMACSHA256.utf8) {
        difference |= lhs ^ rhs
    }
    return difference == 0
}

public func isValidTerminalAuthenticationToken(_ value: String) -> Bool {
    decodeCanonicalHex(value, expectedByteCount: 32) != nil
}

private func isValidAuthenticationNonce(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57)
            || ($0 >= 65 && $0 <= 90)
            || ($0 >= 97 && $0 <= 122)
            || $0 == 45
    }
}

private func decodeCanonicalHex(_ value: String, expectedByteCount: Int) -> Data? {
    let bytes = Array(value.utf8)
    guard bytes.count == expectedByteCount * 2 else { return nil }

    var decoded = Data(capacity: expectedByteCount)
    var index = 0
    while index < bytes.count {
        guard let high = lowercaseHexNibble(bytes[index]),
              let low = lowercaseHexNibble(bytes[index + 1]) else {
            return nil
        }
        decoded.append((high << 4) | low)
        index += 2
    }
    return decoded
}

private func lowercaseHexNibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57:
        byte - 48
    case 97...102:
        byte - 97 + 10
    default:
        nil
    }
}
