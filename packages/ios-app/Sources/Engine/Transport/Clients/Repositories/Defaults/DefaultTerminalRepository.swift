import Foundation

/// Maps native terminal transport operations into the UI-safe repository
/// vocabulary. The repository owns frame decoding and capability discovery;
/// SwiftUI never reaches through the composition root to `EngineClient`.
@MainActor
final class DefaultTerminalRepository: TerminalRepository {
    private let client: EngineClient

    init(client: EngineClient) {
        self.client = client
    }

    var isSupported: Bool {
        client.supportsNativeTerminal
    }

    func setUpdateHandler(_ handler: ((TerminalStreamUpdate) -> Void)?) {
        guard let handler else {
            client.setTerminalFrameHandler(nil)
            return
        }
        client.setTerminalFrameHandler { frame in
            guard let update = TerminalStreamUpdate(frame) else { return }
            handler(update)
        }
    }

    func list(sessionId: String) async throws -> [TerminalSnapshot] {
        try await client.terminal.list(sessionId: sessionId).map(TerminalSnapshot.init)
    }

    func open(
        sessionId: String,
        rows: UInt16,
        columns: UInt16
    ) async throws -> TerminalSnapshot {
        TerminalSnapshot(
            try await client.terminal.open(
                sessionId: sessionId,
                rows: rows,
                columns: columns
            )
        )
    }

    func write(
        _ bytes: [UInt8],
        terminal: TerminalSnapshot,
        inputId: String
    ) async throws {
        try await client.terminal.write(
            bytes,
            terminalId: terminal.id,
            generation: terminal.generation,
            sessionId: terminal.sessionId,
            inputId: inputId
        )
    }

    func resize(
        terminal: TerminalSnapshot,
        rows: UInt16,
        columns: UInt16
    ) async throws {
        try await client.terminal.resize(
            terminalId: terminal.id,
            generation: terminal.generation,
            sessionId: terminal.sessionId,
            rows: rows,
            columns: columns
        )
    }

    func terminate(_ terminal: TerminalSnapshot) async throws {
        try await client.terminal.terminate(
            terminalId: terminal.id,
            generation: terminal.generation,
            sessionId: terminal.sessionId
        )
    }

    func attach(
        terminalId: String,
        attachmentId: String,
        afterSequence: UInt64
    ) async throws -> TerminalAttachmentSnapshot {
        let result = try await client.attachTerminal(
            terminalId,
            attachmentId: attachmentId,
            afterSequence: afterSequence
        )
        return TerminalAttachmentSnapshot(
            attachmentId: result.attachmentId,
            resetRequired: result.resetRequired
        )
    }

    func detach(attachmentId: String) async {
        await client.detachTerminal(attachmentId)
    }
}

private extension TerminalSnapshot {
    init(_ value: TerminalSummaryDTO) {
        self.init(
            id: value.id,
            sessionId: value.sessionId,
            generation: value.generation,
            workingDirectory: value.workingDirectory,
            state: value.state,
            createdAt: value.createdAt,
            exitedAt: value.exitedAt
        )
    }
}

private extension TerminalStreamUpdate {
    init?(_ frame: TerminalInboundFrame) {
        guard let attachmentId = frame.attachmentId else { return nil }
        switch frame.type {
        case "terminal.output":
            guard let sequence = frame.sequence,
                  let encoded = frame.dataBase64,
                  let data = Data(base64Encoded: encoded) else { return nil }
            self = .output(
                attachmentId: attachmentId,
                sequence: sequence,
                bytes: [UInt8](data)
            )
        case "terminal.status":
            self = .status(
                attachmentId: attachmentId,
                state: frame.state,
                exitCode: frame.exitCode,
                lastSequence: frame.lastSequence
            )
        default:
            return nil
        }
    }
}
