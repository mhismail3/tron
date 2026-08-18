import Foundation

struct TerminalSummary: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let sessionId: String
    let cwd: String
    let createdAt: String
    let exitedAt: String?
    let exitCode: Int?
    let sequence: Int
}

struct TerminalChunk: Codable, Hashable, Sendable {
    let sequence: Int
    let data: String
}

enum TerminalInventoryPolicy {
    private struct Response: Encodable {
        let terminals: [TerminalSummary]
    }

    static let maximumTerminals = 128
    static let maximumIDBytes = 100
    static let maximumSessionIDBytes = 200
    static let maximumCWDBytes = 4_096
    static let maximumTimestampBytes = 64
    static let maximumEncodedResponseBytes = 768 * 1_024

    static func admit(
        _ terminals: [TerminalSummary],
        requestedSessionID: String
    ) throws -> [TerminalSummary] {
        guard !requestedSessionID.isEmpty,
              requestedSessionID.utf8.count <= maximumSessionIDBytes,
              terminals.count <= maximumTerminals else {
            throw invalidInventory()
        }
        var identities = Set<String>()
        identities.reserveCapacity(terminals.count)
        for terminal in terminals {
            guard !terminal.id.isEmpty,
                  terminal.id.utf8.count <= maximumIDBytes,
                  terminal.sessionId == requestedSessionID,
                  !terminal.cwd.isEmpty,
                  terminal.cwd.utf8.count <= maximumCWDBytes,
                  !terminal.createdAt.isEmpty,
                  terminal.createdAt.utf8.count <= maximumTimestampBytes,
                  GatewayTimestamp.parse(terminal.createdAt) != nil,
                  terminal.sequence >= 0,
                  identities.insert(terminal.id).inserted else {
                throw invalidInventory()
            }
            guard (terminal.exitedAt == nil) == (terminal.exitCode == nil) else {
                throw invalidInventory()
            }
            if let exitedAt = terminal.exitedAt {
                guard !exitedAt.isEmpty,
                      exitedAt.utf8.count <= maximumTimestampBytes,
                      GatewayTimestamp.parse(exitedAt) != nil else {
                    throw invalidInventory()
                }
            }
        }
        guard let encoded = try? JSONEncoder().encode(Response(terminals: terminals)),
              encoded.count <= maximumEncodedResponseBytes else {
            throw invalidInventory()
        }
        return terminals
    }

    private static func invalidInventory() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_response",
            message: "The terminal list from the Mac is invalid or too large.",
            retryable: true,
            details: nil
        )
    }
}
