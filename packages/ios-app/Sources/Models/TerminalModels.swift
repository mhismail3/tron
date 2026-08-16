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
