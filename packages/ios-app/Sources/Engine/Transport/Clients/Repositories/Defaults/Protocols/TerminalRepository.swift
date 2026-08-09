import Foundation

/// UI-safe terminal identity and retained lifecycle metadata.
///
/// Transport DTOs stay behind the repository boundary so Terminal Mode can be
/// tested and rendered without coupling SwiftUI to the WebSocket client.
struct TerminalSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let generation: UInt64
    let workingDirectory: String
    let state: String
    let createdAt: String
    let exitedAt: String?
}

struct TerminalAttachmentSnapshot: Equatable, Sendable {
    let attachmentId: String
    let resetRequired: Bool
}

/// Ordered updates projected from socket-specific terminal frames.
enum TerminalStreamUpdate: Equatable, Sendable {
    case output(attachmentId: String, sequence: UInt64, bytes: [UInt8])
    case status(
        attachmentId: String,
        state: String?,
        exitCode: Int?,
        lastSequence: UInt64?
    )
}

/// Black-box native terminal contract for session and UI layers.
@MainActor
protocol TerminalRepository: AnyObject {
    var isSupported: Bool { get }

    func setUpdateHandler(_ handler: ((TerminalStreamUpdate) -> Void)?)
    func list(sessionId: String) async throws -> [TerminalSnapshot]
    func open(sessionId: String, rows: UInt16, columns: UInt16) async throws -> TerminalSnapshot
    func write(_ bytes: [UInt8], terminal: TerminalSnapshot, inputId: String) async throws
    func resize(terminal: TerminalSnapshot, rows: UInt16, columns: UInt16) async throws
    func terminate(_ terminal: TerminalSnapshot) async throws
    func attach(
        terminalId: String,
        attachmentId: String,
        afterSequence: UInt64
    ) async throws -> TerminalAttachmentSnapshot
    func detach(attachmentId: String) async
}
