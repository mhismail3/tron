import CoreGraphics
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat morph flight")
struct ChatMorphFlightTests {
    private let target = SessionPresentationIdentity(sessionID: "session", generation: 3)
    private let promptFrame = CGRect(x: 20, y: 600, width: 300, height: 44)
    private let chipFrame = CGRect(x: 250, y: 540, width: 64, height: 64)

    @Test("lifecycle and attachment identity define stable unique endpoints")
    func endpointIdentity() {
        let first = ChatMorphID(
            lifecycleID: "outgoing-submission:session:3:1",
            element: .attachment("upload")
        )
        let second = ChatMorphID(
            lifecycleID: "outgoing-submission:session:3:2",
            element: .attachment("upload")
        )
        #expect(first != second)
        #expect(first.id.contains("upload"))
    }

    @Test("a complete measurement stages one bounded flight")
    func stagesMeasuredFlight() throws {
        let registry = ChatMorphFrameRegistry()
        registry.recordDraftPrompt(frame: promptFrame)
        registry.recordDraftAttachment(id: "upload", frame: chipFrame)
        let lifecycle = lifecycle(nonce: 11, attachment: attachment)

        #expect(registry.stage(lifecycle: lifecycle, generation: 7, suppress: false))
        let flight = try #require(registry.flight)
        #expect(flight.elements.count == 2)
        #expect(!flight.isReady)

        for element in flight.elements {
            registry.recordDestination(
                id: element.id,
                frame: element.id.element == .prompt
                    ? CGRect(x: 40, y: 100, width: 250, height: 52)
                    : CGRect(x: 220, y: 50, width: 64, height: 64)
            )
        }
        let ready = try #require(registry.flight)
        #expect(ready.isReady)
        #expect(registry.beginAnimation(lifecycleID: ready.lifecycleID) != nil)
        #expect(ready.elements.allSatisfy { registry.hidesDestination($0.id) })
    }

    @Test("missing measurements and suppression fail open")
    func failOpenAdmission() {
        let lifecycle = lifecycle(nonce: 12, attachment: attachment)
        let missing = ChatMorphFrameRegistry()
        missing.recordDraftPrompt(frame: promptFrame)
        #expect(!missing.stage(lifecycle: lifecycle, generation: 1, suppress: false))
        #expect(missing.flight == nil)

        let suppressed = ChatMorphFrameRegistry()
        suppressed.recordDraftPrompt(frame: promptFrame)
        suppressed.recordDraftAttachment(id: "upload", frame: chipFrame)
        #expect(!suppressed.stage(lifecycle: lifecycle, generation: 1, suppress: true))
        #expect(suppressed.flight == nil)
    }

    @Test("invalid destination after animation starts fails open")
    func invalidDestinationAfterStart() throws {
        let registry = ChatMorphFrameRegistry()
        registry.recordDraftPrompt(frame: promptFrame)
        let lifecycle = lifecycle(nonce: 14, attachment: nil)
        #expect(registry.stage(lifecycle: lifecycle, generation: 12, suppress: false))
        let id = try #require(registry.flight?.elements.first?.id)
        registry.recordDestination(id: id, frame: CGRect(x: 40, y: 100, width: 250, height: 52))
        #expect(registry.beginAnimation(lifecycleID: lifecycle.id ?? "") != nil)
        registry.recordDestination(id: id, frame: .null)
        #expect(registry.flight == nil)
        #expect(registry.consumeAbandonedGeneration() == 12)
        #expect(registry.consumeAbandonedGeneration() == nil)
    }

    @Test("canonical replacement and foreground retirement clear without replay")
    func reconciliationRetiresFlight() throws {
        let registry = ChatMorphFrameRegistry()
        registry.recordDraftPrompt(frame: promptFrame)
        let lifecycle = lifecycle(nonce: 13, attachment: nil)
        #expect(registry.stage(lifecycle: lifecycle, generation: 9, suppress: false))
        let lifecycleID = try #require(lifecycle.id)
        #expect(registry.reconcile(installedLifecycleID: lifecycleID) == nil)
        #expect(registry.reconcile(installedLifecycleID: nil) == 9)
        #expect(registry.flight == nil)

        registry.recordDraftPrompt(frame: promptFrame)
        #expect(registry.stage(lifecycle: lifecycle, generation: 10, suppress: false))
        #expect(registry.abandon() == 10)
        #expect(registry.abandon() == nil)
    }

    private var attachment: PendingAttachment {
        PendingAttachment(
            id: "upload",
            name: "file.txt",
            mimeType: "text/plain",
            size: 8,
            previewData: nil
        )
    }

    private func lifecycle(
        nonce: UInt64,
        attachment: PendingAttachment?
    ) -> ChatSubmissionLifecycle {
        let attachments = attachment.map { [$0] } ?? []
        return ChatSubmissionLifecycle(
            phase: .staged,
            submission: ComposerSubmissionSnapshot(
                target: target,
                textRevision: 1,
                outgoingText: "Hello",
                attachmentIDs: attachments.map(\.id),
                behavior: nil,
                localNonce: nonce
            ),
            attachments: attachments
        )
    }
}
