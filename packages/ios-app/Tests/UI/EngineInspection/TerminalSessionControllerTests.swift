import Foundation
import Testing

@testable import TronMobile

@Suite("Terminal session controller")
@MainActor
struct TerminalSessionControllerTests {
    @Test("ordered repository updates render once and detach cleanly")
    func orderedUpdatesRenderOnce() async {
        let repository = TerminalRepositoryDouble()
        let controller = TerminalSessionController(
            sessionId: "session",
            repository: repository
        )

        await controller.start()

        #expect(controller.status == "Connected")
        #expect(controller.terminal?.workingDirectory == "/workspace")
        let attachmentId = try! #require(controller.attachmentId)
        repository.emit(.output(attachmentId: attachmentId, sequence: 1, bytes: [65]))
        repository.emit(.output(attachmentId: attachmentId, sequence: 1, bytes: [66]))
        repository.emit(.output(attachmentId: "stale", sequence: 2, bytes: [67]))
        #expect(controller.chunks.map(\.bytes) == [[65]])

        await controller.detach()

        #expect(repository.detachedAttachmentIds == [attachmentId])
        #expect(repository.updateHandler == nil)
    }

    @Test("a capability learned on reconnect retries startup")
    func capabilityLearnedOnReconnectRetriesStartup() async {
        let repository = TerminalRepositoryDouble()
        repository.isSupported = false
        let controller = TerminalSessionController(
            sessionId: "session",
            repository: repository
        )

        await controller.start()
        #expect(controller.terminal == nil)
        #expect(controller.status == "Unavailable")

        repository.isSupported = true
        await controller.reconcile(
            continuity: EngineConnectionContinuity(state: .connected, generation: 1)
        )

        #expect(repository.openCount == 1)
        #expect(controller.status == "Connected")
        #expect(controller.errorMessage == nil)
    }
}

@MainActor
private final class TerminalRepositoryDouble: TerminalRepository {
    var isSupported = true
    var updateHandler: ((TerminalStreamUpdate) -> Void)?
    var openCount = 0
    var detachedAttachmentIds: [String] = []

    func setUpdateHandler(_ handler: ((TerminalStreamUpdate) -> Void)?) {
        updateHandler = handler
    }

    func list(sessionId _: String) async throws -> [TerminalSnapshot] {
        []
    }

    func open(
        sessionId: String,
        rows _: UInt16,
        columns _: UInt16
    ) async throws -> TerminalSnapshot {
        openCount += 1
        return TerminalSnapshot.fixture(sessionId: sessionId)
    }

    func write(
        _ bytes: [UInt8],
        terminal: TerminalSnapshot,
        inputId: String
    ) async throws {}

    func resize(
        terminal: TerminalSnapshot,
        rows: UInt16,
        columns: UInt16
    ) async throws {}

    func terminate(_ terminal: TerminalSnapshot) async throws {}

    func attach(
        terminalId _: String,
        attachmentId: String,
        afterSequence _: UInt64
    ) async throws -> TerminalAttachmentSnapshot {
        TerminalAttachmentSnapshot(
            attachmentId: attachmentId,
            resetRequired: false
        )
    }

    func detach(attachmentId: String) async {
        detachedAttachmentIds.append(attachmentId)
    }

    func emit(_ update: TerminalStreamUpdate) {
        updateHandler?(update)
    }
}

private extension TerminalSnapshot {
    static func fixture(sessionId: String) -> Self {
        Self(
            id: "terminal",
            sessionId: sessionId,
            generation: 1,
            workingDirectory: "/workspace",
            state: "running",
            createdAt: "2026-08-09T00:00:00Z",
            exitedAt: nil
        )
    }
}
