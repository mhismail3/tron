import Foundation
import SwiftTerm
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

    @Test("typing while a write is in flight coalesces into one ordered follow-up")
    func inputCoalescesBehindInFlightWrite() async {
        let repository = TerminalRepositoryDouble()
        repository.suspendNextWrite = true
        let controller = TerminalSessionController(
            sessionId: "session",
            repository: repository
        )
        await controller.start()

        controller.send([65])
        await repository.waitForWriteCount(1)
        controller.send([66])
        controller.send([67])
        controller.send([68])
        #expect(repository.writeCalls.map(\.bytes) == [[65]])

        repository.resumeSuspendedWrite()
        await repository.waitForWriteCount(2)

        let writes = repository.writeCalls
        #expect(writes.map(\.bytes) == [[65], [66, 67, 68]])
        if writes.count == 2 {
            #expect(writes[0].inputId != writes[1].inputId)
        }
    }

    @Test("large input is split at the server's bounded write size")
    func largeInputUsesBoundedBatches() async {
        let repository = TerminalRepositoryDouble()
        let controller = TerminalSessionController(
            sessionId: "session",
            repository: repository
        )
        await controller.start()

        controller.send(Array(repeating: 65, count: 70 * 1024))
        await repository.waitForWriteCount(2)

        #expect(repository.writeCalls.map(\.bytes.count) == [64 * 1024, 6 * 1024])
    }

    @Test("terminal command layouts retain correct navigation sequences")
    func terminalCommandLayout() {
        #expect(TerminalExtendedKey.rows.count == 3)
        #expect(TerminalExtendedKey.rows.allSatisfy { $0.count == 10 })
        #expect(
            TerminalExtendedKey.rows[1].last?.bytes(applicationCursor: false)
                == EscapeSequences.cmdPageUp
        )
        #expect(
            TerminalExtendedKey.rows[2].last?.bytes(applicationCursor: false)
                == EscapeSequences.cmdPageDown
        )
        #expect(
            TerminalCursorKey.left.bytes(applicationCursor: false)
                == EscapeSequences.moveLeftNormal
        )
        #expect(
            TerminalCursorKey.left.bytes(applicationCursor: true)
                == EscapeSequences.moveLeftApp
        )
    }

    @Test("terminal surface stays native and keyboard controls remain unambiguous")
    func terminalSurfaceContract() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent(
                "Sources/UI/SessionContext/TerminalSessionSheet.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("SettingsPageContainer(\n            title: \"Terminal\""))
        #expect(source.contains("view.backgroundColor = .clear"))
        #expect(source.contains("view.nativeBackgroundColor = .clear"))
        #expect(source.contains(".glassEffect("))
        #expect(source.contains("accessibilityLabel: \"Command keys\""))
        #expect(source.contains("accessibilityLabel: \"Dismiss keyboard\""))
        #expect(!source.contains(".background(Color(uiColor: .systemBackground))"))
    }

    private func iosAppRoot(filePath: String = #filePath) throws -> URL {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("project.yml").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

@MainActor
private final class TerminalRepositoryDouble: TerminalRepository {
    struct WriteCall {
        let bytes: [UInt8]
        let terminal: TerminalSnapshot
        let inputId: String
    }

    var isSupported = true
    var updateHandler: ((TerminalStreamUpdate) -> Void)?
    var openCount = 0
    var detachedAttachmentIds: [String] = []
    var writeCalls: [WriteCall] = []
    var suspendNextWrite = false
    private var suspendedWriteContinuation: CheckedContinuation<Void, Never>?

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
    ) async throws {
        writeCalls.append(WriteCall(bytes: bytes, terminal: terminal, inputId: inputId))
        guard suspendNextWrite else { return }
        suspendNextWrite = false
        await withCheckedContinuation { continuation in
            suspendedWriteContinuation = continuation
        }
    }

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

    func resumeSuspendedWrite() {
        let continuation = suspendedWriteContinuation
        suspendedWriteContinuation = nil
        continuation?.resume()
    }

    func waitForWriteCount(_ expectedCount: Int) async {
        for _ in 0 ..< 1_000 {
            if writeCalls.count >= expectedCount { return }
            await Task.yield()
        }
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
