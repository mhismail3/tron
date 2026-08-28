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
        #expect(flight.elements.last?.id.element == .attachment("upload"))
        #expect(flight.elements.last?.attachment?.transportBlobID == "upload:gateway-upload")
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

    @Test("compact prompts morph while long prompts use the bounded row entrance")
    func compactPromptAdmission() {
        #expect(ChatMorphAdmissionPolicy.admitsPrompt(
            text: "A compact prompt",
            sourceFrame: promptFrame,
            reduceMotion: false
        ))
        #expect(!ChatMorphAdmissionPolicy.admitsPrompt(
            text: String(repeating: "long ", count: 80),
            sourceFrame: promptFrame,
            reduceMotion: false
        ))
        #expect(!ChatMorphAdmissionPolicy.admitsPrompt(
            text: "Tall prompt",
            sourceFrame: CGRect(x: 20, y: 400, width: 300, height: 180),
            reduceMotion: false
        ))
        #expect(!ChatMorphAdmissionPolicy.admitsPrompt(
            text: "Reduced motion",
            sourceFrame: promptFrame,
            reduceMotion: true
        ))
    }

    @Test("queued card submissions use their exact bounded row entrance")
    func queuedCardAdmission() {
        let registry = ChatMorphFrameRegistry()
        registry.recordDraftPrompt(frame: promptFrame)
        #expect(!registry.stage(
            lifecycle: lifecycle(nonce: 18, attachment: nil, behavior: "steer"),
            generation: 4,
            suppress: false
        ))
        #expect(registry.flight == nil)
    }

    @Test("attachment-only submissions remain eligible for measured morphs")
    func attachmentOnlyAdmission() {
        let registry = ChatMorphFrameRegistry()
        registry.recordDraftAttachment(id: "upload", frame: chipFrame)
        #expect(registry.stage(
            lifecycle: lifecycle(nonce: 15, attachment: attachment, text: ""),
            generation: 4,
            suppress: false
        ))
    }

    @Test("failed and completed flights resolve row entrance ownership exactly once")
    func entranceOwnershipResolution() throws {
        let lifecycle = lifecycle(nonce: 16, attachment: nil)
        let lifecycleID = try #require(lifecycle.id)

        let failed = ChatMorphFrameRegistry()
        failed.recordDraftPrompt(frame: promptFrame)
        #expect(failed.stage(lifecycle: lifecycle, generation: 5, suppress: false))
        #expect(failed.entranceOwnership(for: lifecycleID) == .flight)
        #expect(failed.failOpen(lifecycleID: lifecycleID) == 5)
        #expect(failed.entranceOwnership(for: lifecycleID) == .ordinary)

        let completed = ChatMorphFrameRegistry()
        completed.recordDraftPrompt(frame: promptFrame)
        #expect(completed.stage(lifecycle: lifecycle, generation: 6, suppress: false))
        let id = try #require(completed.flight?.elements.first?.id)
        completed.recordDestination(id: id, frame: CGRect(x: 40, y: 100, width: 250, height: 52))
        #expect(completed.beginAnimation(lifecycleID: lifecycleID) != nil)
        #expect(completed.completeAnimation(lifecycleID: lifecycleID) == 6)
        #expect(completed.entranceOwnership(for: lifecycleID) == .completed)
        #expect(completed.reconcile(installedLifecycleID: nil) == nil)
        #expect(completed.entranceOwnership(for: lifecycleID) == .ordinary)
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

    @Test("destination retargeting ignores subpixel geometry churn")
    func destinationRetargetTolerance() {
        let base = CGRect(x: 40, y: 100, width: 250, height: 52)
        #expect(ChatMorphFramePolicy.materiallyDiffers(nil, from: base))
        #expect(!ChatMorphFramePolicy.materiallyDiffers(
            base,
            from: base.offsetBy(dx: 0.25, dy: -0.25)
        ))
        #expect(ChatMorphFramePolicy.materiallyDiffers(
            base,
            from: base.offsetBy(dx: 0, dy: 1)
        ))
    }

    @Test("a valid destination may retarget while the keyboard settles")
    func validDestinationRetargetsContinuously() throws {
        let registry = ChatMorphFrameRegistry()
        registry.recordDraftPrompt(frame: promptFrame)
        let lifecycle = lifecycle(nonce: 17, attachment: nil)
        #expect(registry.stage(lifecycle: lifecycle, generation: 13, suppress: false))
        let id = try #require(registry.flight?.elements.first?.id)
        let initial = CGRect(x: 40, y: 100, width: 250, height: 52)
        let settled = CGRect(x: 40, y: 92, width: 250, height: 52)
        registry.recordDestination(id: id, frame: initial)
        #expect(registry.beginAnimation(lifecycleID: lifecycle.id ?? "") != nil)
        registry.recordDestination(id: id, frame: settled)
        #expect(registry.flight?.phase == .animating)
        #expect(registry.flight?.destinationFrames[id] == settled)
        #expect(registry.consumeAbandonedGeneration() == nil)
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

    @Test("preflight card replacement fails an ordinary prompt flight open")
    func preflightCardRetiresFlight() throws {
        let registry = ChatMorphFrameRegistry()
        registry.recordDraftPrompt(frame: promptFrame)
        let lifecycle = lifecycle(nonce: 19, attachment: nil)
        let lifecycleID = try #require(lifecycle.id)
        #expect(registry.stage(lifecycle: lifecycle, generation: 14, suppress: false))
        #expect(registry.reconcile(
            installedLifecycleID: lifecycleID,
            permitsFlight: false
        ) == 14)
        #expect(registry.flight == nil)
        #expect(registry.entranceOwnership(for: lifecycleID) == .ordinary)
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
            gatewayUploadID: "gateway-upload",
            name: "file.txt",
            mimeType: "text/plain",
            size: 8,
            previewData: nil
        )
    }

    private func lifecycle(
        nonce: UInt64,
        attachment: PendingAttachment?,
        text: String = "Hello",
        behavior: String? = nil
    ) -> ChatSubmissionLifecycle {
        let attachments = attachment.map { [$0] } ?? []
        return ChatSubmissionLifecycle(
            phase: .staged,
            submission: ComposerSubmissionSnapshot(
                target: target,
                textRevision: 1,
                outgoingText: text,
                attachmentIDs: attachments.compactMap(\.gatewayUploadID),
                behavior: behavior,
                localNonce: nonce
            ),
            attachments: attachments
        )
    }
}
