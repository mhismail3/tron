import Foundation

struct TerminalSummaryDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let generation: UInt64
    let workingDirectory: String
    let shell: String
    let state: String
    let rows: UInt16
    let columns: UInt16
    let earliestSequence: UInt64
    let latestSequence: UInt64
    let createdAt: String
    let updatedAt: String
    let exitedAt: String?
    let exitCode: Int?
    let interruptionReason: String?
    let retainedUntil: String
}

struct TerminalListDTO: Decodable, Sendable { let terminals: [TerminalSummaryDTO] }
struct TerminalOpenDTO: Decodable, Sendable { let terminal: TerminalSummaryDTO }
struct TerminalWriteDTO: Decodable, Sendable { let accepted: Bool; let duplicate: Bool; let inputId: String }
struct TerminalResizeDTO: Decodable, Sendable { let resized: Bool; let rows: UInt16; let columns: UInt16 }
struct TerminalTerminateDTO: Decodable, Sendable { let terminating: Bool }

@MainActor
final class TerminalClient: EngineDomainClient {
    func list(sessionId: String) async throws -> [TerminalSummaryDTO] {
        let result: TerminalListDTO = try await invokeRead("terminal::list", ["sessionId": sessionId])
        return result.terminals
    }

    func open(sessionId: String, rows: UInt16, columns: UInt16) async throws -> TerminalSummaryDTO {
        let result: TerminalOpenDTO = try await invokeWrite(
            "terminal::open",
            OpenRequest(sessionId: sessionId, rows: rows, columns: columns),
            idempotencyKey: .userAction("terminal-open-\(sessionId)-\(UUID().uuidString)"),
            context: sessionInvocationContext(sessionId)
        )
        return result.terminal
    }

    func write(_ bytes: [UInt8], terminal: TerminalSummaryDTO, inputId: String) async throws {
        let _: TerminalWriteDTO = try await invokeWrite(
            "terminal::write",
            WriteRequest(terminalId: terminal.id, generation: terminal.generation, inputId: inputId, dataBase64: Data(bytes).base64EncodedString()),
            idempotencyKey: EngineIdempotencyKey(rawValue: "terminal-input:\(terminal.id):\(inputId)"),
            context: sessionInvocationContext(terminal.sessionId)
        )
    }

    func resize(terminal: TerminalSummaryDTO, rows: UInt16, columns: UInt16) async throws {
        let _: TerminalResizeDTO = try await invokeWrite(
            "terminal::resize",
            ResizeRequest(terminalId: terminal.id, generation: terminal.generation, rows: rows, columns: columns),
            idempotencyKey: .userAction("terminal-resize-\(terminal.id)-\(terminal.generation)-\(rows)x\(columns)"),
            context: sessionInvocationContext(terminal.sessionId)
        )
    }

    func terminate(_ terminal: TerminalSummaryDTO) async throws {
        let _: TerminalTerminateDTO = try await invokeWrite(
            "terminal::terminate",
            IdentityRequest(terminalId: terminal.id, generation: terminal.generation),
            idempotencyKey: .userAction("terminal-terminate-\(terminal.id)"),
            context: sessionInvocationContext(terminal.sessionId)
        )
    }

    private struct OpenRequest: Encodable { let sessionId: String; let rows: UInt16; let columns: UInt16 }
    private struct WriteRequest: Encodable { let terminalId: String; let generation: UInt64; let inputId: String; let dataBase64: String }
    private struct ResizeRequest: Encodable { let terminalId: String; let generation: UInt64; let rows: UInt16; let columns: UInt16 }
    private struct IdentityRequest: Encodable { let terminalId: String; let generation: UInt64 }
}
