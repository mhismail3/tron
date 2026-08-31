import Foundation
import Testing
@testable import TronMobile

@Suite("Chat transcript presentation")
struct ChatTranscriptPresentationTests {
    @Test("producer session messages derive one typed compact status and optional duration")
    func compactSessionInputPresentation() {
        #expect(InboundContextCompactPresentationPolicy.status(
            details: .object(["status": .string("in_progress")])
        ) == "In Progress")
        #expect(InboundContextCompactPresentationPolicy.status(
            details: .object(["goal": .object(["status": .string("complete")])])
        ) == "Completed")
        #expect(InboundContextCompactPresentationPolicy.status(details: .object([
            "status": .string("count to 20"),
        ])) == "Received")
        #expect(InboundContextCompactPresentationPolicy.status(details: nil) == "Received")
        #expect(InboundContextCompactPresentationPolicy.durationMilliseconds(
            details: .object(["durationMs": .number(42)])
        ) == 42)
        #expect(InboundContextCompactPresentationPolicy.durationMilliseconds(
            details: .object(["elapsedMs": .number(-4)])
        ) == 0)
    }

    @Test("unknown context omits a producer without inventing one")
    func unknownContextTitle() {
        #expect(InboundProducerPresentationPolicy.title(for: nil) == "Unknown source")
        #expect(InboundProducerPresentationPolicy.compactTitle(for: nil) == "Context")
        #expect(InboundProducerPresentationPolicy.messageType("subagent_supervisor_request")
            == "Subagent Supervisor Request")
        #expect(InboundProducerPresentationPolicy.title(
            for: ChatOrigin(kind: .extension, title: "Trusted Adapter", confidence: .receipt)
        ) == "Trusted Adapter")
    }

    @Test("inbound delivery metadata remains truthful in technical details")
    func inboundDeliveryLabels() {
        #expect(InboundProducerPresentationPolicy.deliveryLabel(for: .stored) == "Stored for model context")
        #expect(InboundProducerPresentationPolicy.deliveryLabel(for: .triggeredTurn) == "Triggered an agent turn")
        #expect(InboundProducerPresentationPolicy.deliveryLabel(for: .followUp) == "Queued as a follow-up")
        #expect(InboundProducerPresentationPolicy.deliveryLabel(for: nil) == "Unknown")
    }

    @Test("prompt behavior normalizes wire values before first rendering")
    func promptBehaviorNormalization() {
        #expect(ChatPromptBehavior(rawValue: nil) == .ordinary)
        #expect(ChatPromptBehavior(rawValue: "steer") == .steer)
        #expect(ChatPromptBehavior(rawValue: "followUp") == .followUp)
        #expect(ChatPromptBehavior(rawValue: "future-mode") == .unknown)
        #expect(ChatPromptBehavior(rawValue: "steer").isQueuedKind)
        #expect(!ChatPromptBehavior(rawValue: nil).isQueuedKind)
    }

    @Test("handoff behavior selects the first-frame component kind")
    func handoffBehaviorSelectsFirstFrameKind() {
        let target = SessionPresentationIdentity(sessionID: "session", generation: 1)
        func behavior(_ raw: String?) -> ChatPromptBehavior {
            ChatTranscriptHandoffCommit.outgoing(
                presentation: ChatOutgoingSubmissionPresentation(
                    snapshot: ComposerSubmissionSnapshot(
                        target: target, textRevision: 1, outgoingText: "prompt",
                        attachmentIDs: [], behavior: raw, localNonce: 1
                    ),
                    transportActive: true
                ),
                attachments: []
            ).promptBehavior
        }
        #expect(behavior(nil) == .ordinary)
        #expect(behavior("steer") == .steer)
        #expect(behavior("followUp") == .followUp)
        #expect(behavior("unrecognized") == .unknown)
        let preflight = ChatOutgoingSubmissionPresentation(
            snapshot: ComposerSubmissionSnapshot(
                target: target, textRevision: 1, outgoingText: "prompt",
                attachmentIDs: [], behavior: nil, localNonce: 2
            ),
            transportActive: true,
            preflightCompacting: true
        )
        #expect(preflight.promptBehavior == .ordinary)
        #expect(preflight.usesQueuedCardVisual)
        #expect(preflight.cardBehavior == .steer)
        #expect(preflight.cardTitle == "Message")
        #expect(preflight.cardDetail == "After compaction")
        #expect(ChatPromptLifecycleTransitionPolicy.entranceKind(for: behavior("steer")) == .queuedPrompt)
        #expect(ChatPromptLifecycleTransitionPolicy.entranceKind(for: behavior("followUp")) == .queuedPrompt)
        #expect(ChatPromptLifecycleTransitionPolicy.entranceKind(for: behavior(nil)) == .userPrompt)
    }
    @Test("pending direct prompts consume canonical entrance entitlement exactly once")
    func pendingCanonicalReplacementSuppressesSecondEntrance() throws {
        let pending = SessionSnapshot.PendingPrompt(
            id: "operation-1",
            createdAt: "2026-01-01T00:00:01Z",
            behavior: nil,
            text: "hello",
            attachmentCount: 0
        )
        let data = Data(#"{"id":"canonical","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"hello"}]}"#.utf8)
        let canonical = try decodeTranscriptFixture(TranscriptItem.self, from: data)
        let ids = ChatPendingCanonicalSuppressionPolicy.canonicalIDs(
            for: pending,
            in: [canonical]
        )
        #expect(ids == ["canonical"])
        #expect(ChatPendingCanonicalSuppressionPolicy.suppresses(pending, in: [canonical]))
        // The owning ChatView records the exact pending operation as
        // `queued-message-operation-1` in its suppression ledger when a
        // pending prompt becomes a queue item; the queue entrance is then
        // intentionally not replayed.
        #expect(!ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
            isReady: true,
            entranceSuppressed: false,
            hasIdentityAlias: true
        ))
    }

    @Test("pending resource presentation preserves exact invocation identity")
    func pendingResourcePresentationPreservesInvocation() {
        let resource = ComposerResourceInvocation(
            source: .skill, name: "review", arguments: "Inspect this"
        )
        let pending = SessionSnapshot.PendingPrompt(
            id: "operation-resource",
            createdAt: "2026-01-01T00:00:01Z",
            behavior: nil,
            text: "Inspect this",
            attachmentCount: 0,
            resourceInvocation: resource
        )
        let presentation = ChatPendingPromptPresentation(
            snapshot: pending, isCompacting: false
        )
        #expect(presentation.resourceInvocation == resource)
    }

    @Test("pending canonical replacement prefers exact operation identity over repeated text")
    func pendingCanonicalReplacementPrefersOperationIdentity() throws {
        let pending = SessionSnapshot.PendingPrompt(
            id: "operation-exact",
            createdAt: "2026-01-01T00:00:01Z",
            behavior: nil,
            text: "same",
            attachmentCount: 0
        )
        let unrelated = try decodeTranscriptFixture(TranscriptItem.self, from: Data(
            #"{"id":"unrelated","parentId":null,"presentationId":"other","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"text-a","type":"text","text":"same"}]}"#.utf8
        ))
        let exact = try decodeTranscriptFixture(TranscriptItem.self, from: Data(
            #"{"id":"exact","parentId":"unrelated","presentationId":"operation-exact","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"user","content":[{"id":"text-b","type":"text","text":"same"}]}"#.utf8
        ))
        #expect(ChatPendingCanonicalSuppressionPolicy.canonicalIDs(
            for: pending,
            in: [unrelated, exact]
        ) == ["exact"])
        let presentation = ChatPendingPromptPresentation(snapshot: pending, isCompacting: true)
        #expect(ChatPendingCanonicalSuppressionPolicy.exactCanonicalID(
            for: presentation,
            in: [unrelated, exact]
        ) == "exact")
        #expect(ChatPendingCanonicalSuppressionPolicy.exactCanonicalID(
            for: presentation,
            in: [unrelated]
        ) == nil)
        #expect(ChatPendingCanonicalSuppressionPolicy.canonicalIDs(
            for: pending,
            in: [exact, exact]
        ).isEmpty)
        #expect(ChatPendingCanonicalSuppressionPolicy.exactCanonicalID(
            for: presentation,
            in: [exact, exact]
        ) == nil)

        let submission = ComposerSubmissionSnapshot(
            target: .init(sessionID: "session", generation: 1),
            textRevision: 1,
            outgoingText: "same",
            attachmentIDs: [],
            behavior: nil,
            localNonce: 1
        )
        let exactReceipt = CanonicalSubmissionHandoffReceipt(
            canonicalID: exact.id,
            attachments: [],
            operationID: pending.id,
            submission: submission
        )
        #expect(ChatCanonicalSubmissionAliasPolicy.alias(
            for: exactReceipt,
            in: [unrelated, exact]
        ) == ChatCanonicalSubmissionAlias(
            canonicalID: exact.id,
            presentationID: submission.presentationID
        ))
        let unrelatedReceipt = CanonicalSubmissionHandoffReceipt(
            canonicalID: unrelated.id,
            attachments: [],
            operationID: pending.id,
            submission: submission
        )
        #expect(ChatCanonicalSubmissionAliasPolicy.alias(
            for: unrelatedReceipt,
            in: [unrelated, exact]
        ) == nil)
    }

    @Test("previous installed pending handoff suppresses replacement when new snapshot omits pending")
    func previousPendingHandoffSuppressesReplacement() throws {
        let pending = ChatPendingPromptPresentation(
            snapshot: .init(
                id: "operation-2",
                createdAt: "2026-01-01T00:00:01Z",
                behavior: .steer,
                text: "steer now",
                attachmentCount: 0
            ),
            isCompacting: false
        )
        let data = Data(#"{"id":"canonical-2","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"steer now"}]}"#.utf8)
        let canonical = try decodeTranscriptFixture(TranscriptItem.self, from: data)
        // This models the next authoritative snapshot: pendingPrompt is gone,
        // but the canonical row is now present. The prior installed handoff is
        // the only owner that can identify the replacement.
        #expect(ChatPendingCanonicalSuppressionPolicy.canonicalIDs(
            for: pending,
            in: [canonical]
        ) == ["canonical-2"])
        // Same-text compatibility suppression avoids a duplicate entrance but
        // cannot transfer physical identity without exact operation causality.
        #expect(ChatPendingCanonicalSuppressionPolicy.exactCanonicalID(
            for: pending,
            in: [canonical]
        ) == nil)
        #expect(!ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
            isReady: true,
            entranceSuppressed: false,
            hasIdentityAlias: true
        ))
        #expect(ChatContentTransitionPolicy.revealAnimation(
            for: .userPrompt,
            reduceMotion: false
        ) != ChatContentTransitionPolicy.revealAnimation(
            for: .userPrompt,
            reduceMotion: true
        ))
    }

    @Test("queued replacement suppresses only the exact pending operation identity")
    func previousPendingQueueReplacementUsesOperationID() {
        let pending = ChatPendingPromptPresentation(
            snapshot: .init(
                id: "operation-3",
                createdAt: "2026-01-01T00:00:01Z",
                behavior: .followUp,
                text: "follow up",
                attachmentCount: 0
            ),
            isCompacting: false
        )
        let queue = SessionSnapshot.QueuedMessage(
            id: "operation-3",
            behavior: .followUp,
            text: "follow up",
            attachmentCount: 0
        )
        let unrelated = SessionSnapshot.QueuedMessage(
            id: "operation-other",
            behavior: .followUp,
            text: "follow up",
            attachmentCount: 0
        )
        #expect(queue.id == pending.id)
        #expect(unrelated.id != pending.id)
        #expect(ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
            isReady: true,
            entranceSuppressed: false,
            hasIdentityAlias: true
        ) == false)
    }

    @Test("queue-to-canonical replacement requires one exact mixed-attachment candidate")
    func queueToCanonicalReplacement() throws {
        let queued = SessionSnapshot.QueuedMessage(
            id: "operation-mixed",
            behavior: .steer,
            text: "ship it",
            attachmentCount: 2,
            photoCount: 1,
            fileAttachmentCount: 1
        )
        let canonical = try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data(#"{"id":"canonical-mixed","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","presentationId":"canonical-mixed","content":[{"id":"text","ordinal":0,"type":"text","text":"ship it"},{"id":"photo","ordinal":1,"type":"image","text":null,"mimeType":"image/jpeg"},{"id":"file","ordinal":2,"type":"text","text":null,"attachment":{"name":"notes.txt","mimeType":"text/plain","size":3}}]}"#.utf8)
        )
        let canonicalHandoffID = ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
            previousQueue: [queued],
            incomingQueue: [],
            previousCanonicalIDs: [],
            incomingTranscript: [canonical]
        )
        #expect(canonicalHandoffID == "canonical-mixed")
        #expect(ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
            previousQueue: [queued],
            incomingQueue: [],
            excludedOperationIDs: [queued.id],
            previousCanonicalIDs: [],
            incomingTranscript: [canonical]
        ) == nil)
    }

    @Test("canonical media previews map exact files and only an exact ordered image sequence")
    func canonicalMediaPreviewMapping() throws {
        let photoPreview = Data([1, 2])
        let filePreview = Data([3, 4])
        let attachments = [
            PendingAttachment(
                id: "photo-upload", name: "photo.jpg", mimeType: "image/jpeg", size: 2,
                previewData: photoPreview
            ),
            PendingAttachment(
                id: "local-file-chip", gatewayUploadID: "file-upload",
                name: "notes.txt", mimeType: "text/plain", size: 2,
                previewData: filePreview
            ),
        ]
        let canonical = try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data(#"{"id":"canonical-media","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","presentationId":"canonical-media","content":[{"id":"text","ordinal":0,"type":"text","text":"ship it"},{"id":"photo","ordinal":1,"type":"image","mimeType":"image/jpeg","blobId":"image-blob"},{"id":"file","ordinal":2,"type":"text","text":"notes.txt","blobId":"upload:file-upload","attachment":{"name":"notes.txt","mimeType":"text/plain","size":2}}]}"#.utf8)
        )
        #expect(ChatCanonicalMediaPreviewPolicy.seeds(
            attachments: attachments,
            canonicalItem: canonical
        ) == [
            .init(blobID: "image-blob", attachment: attachments[0]),
            .init(blobID: "upload:file-upload", attachment: attachments[1]),
        ])

        let mismatchedImage = PendingAttachment(
            id: "photo-upload", name: "photo.png", mimeType: "image/png", size: 2,
            previewData: photoPreview
        )
        #expect(ChatCanonicalMediaPreviewPolicy.seeds(
            attachments: [mismatchedImage, attachments[1]],
            canonicalItem: canonical
        ) == [.init(blobID: "upload:file-upload", attachment: attachments[1])])
    }

    @Test("attachment-only queue replacement admits Pi envelope only with exact typed counts")
    func attachmentOnlyQueueReplacement() throws {
        let queued = SessionSnapshot.QueuedMessage(
            id: "operation-attachment", behavior: .steer, text: "",
            attachmentCount: 1, photoCount: 1, fileAttachmentCount: 0
        )
        let canonical = try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data(#"{"id":"canonical-attachment","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","presentationId":"canonical-attachment","content":[{"id":"envelope","ordinal":0,"type":"text","text":"[Attached image context]"},{"id":"photo","ordinal":1,"type":"image","text":null,"mimeType":"image/jpeg"}]}"#.utf8)
        )
        #expect(ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
            previousQueue: [queued], incomingQueue: [], previousCanonicalIDs: [], incomingTranscript: [canonical]
        ) == "canonical-attachment")
        let untyped = SessionSnapshot.QueuedMessage(
            id: queued.id, behavior: queued.behavior, text: "", attachmentCount: 1
        )
        #expect(ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
            previousQueue: [untyped], incomingQueue: [], previousCanonicalIDs: [], incomingTranscript: [canonical]
        ) == nil)
    }

    @Test("queue-to-canonical replacement fails closed for ambiguity and multiple removals")
    func queueToCanonicalReplacementAmbiguity() throws {
        let first = SessionSnapshot.QueuedMessage(
            id: "operation-one", behavior: .followUp, text: "repeat", attachmentCount: 0
        )
        let second = SessionSnapshot.QueuedMessage(
            id: "operation-two", behavior: .followUp, text: "other", attachmentCount: 0
        )
        let candidateOne = try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data(#"{"id":"canonical-one","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","presentationId":"canonical-one","content":[{"id":"text","ordinal":0,"type":"text","text":"repeat"}]}"#.utf8)
        )
        let candidateTwo = try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data(#"{"id":"canonical-two","parentId":null,"timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"user","presentationId":"canonical-two","content":[{"id":"text","ordinal":0,"type":"text","text":"repeat"}]}"#.utf8)
        )
        #expect(ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
            previousQueue: [first], incomingQueue: [], previousCanonicalIDs: [],
            incomingTranscript: [candidateOne, candidateTwo]
        ) == nil)
        #expect(ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
            previousQueue: [first, second], incomingQueue: [], previousCanonicalIDs: [],
            incomingTranscript: [candidateOne]
        ) == nil)
    }

    @Test("queue-to-canonical replacement preserves canonical identity and ignores old transcript")
    func queueToCanonicalReplacementIdentity() throws {
        let queued = SessionSnapshot.QueuedMessage(
            id: "operation-stable", behavior: .steer, text: "same", attachmentCount: 0
        )
        let old = try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data(#"{"id":"old","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","presentationId":"old","content":[{"id":"text","ordinal":0,"type":"text","text":"same"}]}"#.utf8)
        )
        #expect(ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
            previousQueue: [queued], incomingQueue: [], previousCanonicalIDs: ["old"],
            incomingTranscript: [old]
        ) == nil)
    }

    @Test("prepended history cannot become a forward queue replacement candidate")
    func prependedHistoryFailsForwardTailAdmission() {
        #expect(!ChatPromptLifecycleReplacementPolicy.isForwardTailCandidate(
            itemID: "older-repeat",
            previousSourceIDs: ["prior-a", "prior-b"],
            incomingSourceIDs: ["older-repeat", "prior-a", "prior-b"]
        ))
        #expect(ChatPromptLifecycleReplacementPolicy.isForwardTailCandidate(
            itemID: "new-repeat",
            previousSourceIDs: ["prior-a", "prior-b"],
            incomingSourceIDs: ["prior-a", "prior-b", "new-repeat"]
        ))
    }

    @Test("timestamped pending suppression rejects repeated matching canonical rows")
    func pendingSuppressionRejectsAmbiguousMatches() throws {
        let pending = SessionSnapshot.PendingPrompt(
            id: "pending-repeat", createdAt: "2026-01-01T00:00:01Z", behavior: nil,
            text: "repeat", attachmentCount: 0
        )
        let first = try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data(#"{"id":"canonical-a","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"text","ordinal":0,"type":"text","text":"repeat"}]}"#.utf8)
        )
        let second = try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data(#"{"id":"canonical-b","parentId":null,"timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"user","content":[{"id":"text","ordinal":0,"type":"text","text":"repeat"}]}"#.utf8)
        )
        #expect(ChatPendingCanonicalSuppressionPolicy.canonicalIDs(
            for: pending, in: [first, second]
        ).isEmpty)
    }

    @Test("native visible edge is authoritative over independently settling inset fields")
    func nativeVisibleBottomDistance() {
        let geometry = ChatTranscriptGeometry(
            offsetY: 400,
            contentHeight: 1_000,
            containerHeight: 400,
            bottomInset: 200,
            visibleBottomY: 1_200
        )

        #expect(geometry.distanceFromBottom == 0)
        #expect(geometry.isAtCatchUpBoundary)
    }

    @Test("physical bottom edge includes inset and rejects overshoot smaller than that inset")
    func insetBottomEdge() {
        let bottom = ChatTranscriptGeometry(
            offsetY: 800,
            contentHeight: 1_000,
            containerHeight: 400,
            bottomInset: 200,
            visibleTopY: 800,
            visibleBottomY: 1_200
        )
        let overshootWithinInsetMagnitude = ChatTranscriptGeometry(
            offsetY: 850,
            contentHeight: 1_000,
            containerHeight: 400,
            bottomInset: 200,
            visibleTopY: 850,
            visibleBottomY: 1_250
        )
        let undersized = ChatTranscriptGeometry(
            offsetY: 0,
            contentHeight: 180,
            containerHeight: 400,
            bottomInset: 50,
            visibleTopY: 0,
            visibleBottomY: 400
        )
        let undersizedOvershoot = ChatTranscriptGeometry(
            offsetY: 10,
            contentHeight: 180,
            containerHeight: 400,
            bottomInset: 50,
            visibleTopY: 10,
            visibleBottomY: 410
        )

        #expect(bottom.distanceFromBottom == 0)
        #expect(!bottom.isPastBottomEdge)
        #expect(bottom.isAtCatchUpBoundary)
        #expect(overshootWithinInsetMagnitude.distanceFromBottom == 0)
        #expect(overshootWithinInsetMagnitude.isPastBottomEdge)
        #expect(!overshootWithinInsetMagnitude.isAtCatchUpBoundary)
        #expect(!undersized.isPastBottomEdge)
        #expect(undersized.isAtCatchUpBoundary)
        #expect(!undersizedOvershoot.isPastBottomEdge)
        #expect(undersizedOvershoot.isAtCatchUpBoundary)
    }

    @Test("past-bottom fallback uses offset when native visible edges are unavailable")
    func pastBottomEdgeOffsetFallback() {
        let bottom = ChatTranscriptGeometry(
            offsetY: 600,
            contentHeight: 1_000,
            containerHeight: 400
        )
        let overshoot = ChatTranscriptGeometry(
            offsetY: 600,
            contentHeight: 900,
            containerHeight: 400
        )
        let undersized = ChatTranscriptGeometry(
            offsetY: 0,
            contentHeight: 180,
            containerHeight: 400
        )
        let undersizedOvershoot = ChatTranscriptGeometry(
            offsetY: 3,
            contentHeight: 180,
            containerHeight: 400
        )

        #expect(!bottom.isPastBottomEdge)
        #expect(overshoot.isPastBottomEdge)
        #expect(!undersized.isPastBottomEdge)
        #expect(!undersizedOvershoot.isPastBottomEdge)
    }

    @Test("opening plausibility distinguishes a physical tail from overflow overshoot")
    func openingViewportPlausibility() {
        let bottom = ChatTranscriptGeometry(
            offsetY: 600,
            contentHeight: 1_000,
            containerHeight: 400,
            visibleBottomY: 1_000
        )
        let overshoot = ChatTranscriptGeometry(
            offsetY: 1_200,
            contentHeight: 1_000,
            containerHeight: 400,
            visibleBottomY: 1_600
        )
        let undersized = ChatTranscriptGeometry(
            offsetY: 0,
            contentHeight: 180,
            containerHeight: 400,
            visibleTopY: 0,
            visibleBottomY: 400
        )
        let undersizedOvershoot = ChatTranscriptGeometry(
            offsetY: 100,
            contentHeight: 180,
            containerHeight: 400,
            visibleTopY: 100,
            visibleBottomY: 500
        )

        #expect(bottom.isPlausibleOpeningViewport)
        #expect(bottom.isAtCatchUpBoundary)
        #expect(!bottom.isPastBottomEdge)
        #expect(!overshoot.isPlausibleOpeningViewport)
        #expect(overshoot.isPastBottomEdge)
        #expect(!overshoot.isAtCatchUpBoundary)
        #expect(undersized.isPlausibleOpeningViewport)
        #expect(!undersized.isPastBottomEdge)
        #expect(undersizedOvershoot.isPlausibleOpeningViewport)
        #expect(!undersizedOvershoot.isPastBottomEdge)
        #expect(undersizedOvershoot.isAtCatchUpBoundary)
    }

    @Test("physical tail evidence uses signed marker displacement")
    func physicalTailEvidenceClassification() {
        let aligned = ChatPhysicalTailEvidence.make(
            presentationEpoch: 4,
            layoutEpoch: 9,
            semanticFrameRevision: 12,
            markerFrame: CGRect(x: 0, y: 388, width: 1, height: 12),
            visibleBounds: CGRect(x: 0, y: 0, width: 1, height: 400)
        )
        #expect(aligned.classification == .aligned)
        #expect(aligned.signedDisplacement == 0)

        let below = ChatPhysicalTailEvidence.make(
            presentationEpoch: 4,
            layoutEpoch: 9,
            semanticFrameRevision: 13,
            markerFrame: CGRect(x: 0, y: 300, width: 1, height: 12),
            visibleBounds: CGRect(x: 0, y: 0, width: 1, height: 400)
        )
        #expect(below.classification == .belowViewport)
        #expect(below.signedDisplacement < 0)

        let above = ChatPhysicalTailEvidence.make(
            presentationEpoch: 4,
            layoutEpoch: 9,
            semanticFrameRevision: 14,
            markerFrame: CGRect(x: 0, y: 500, width: 1, height: 12),
            visibleBounds: CGRect(x: 0, y: 0, width: 1, height: 400)
        )
        #expect(above.classification == .aboveViewport)
        #expect(above.signedDisplacement > 0)
    }

    @Test("finalized invocation groups keep complete membership and stable identity")
    func finalizedInvocationGroupIdentity() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant-tools","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","presentationId":"stream:turn","content":[
            {"id":"stream:turn:0","ordinal":0,"type":"toolCall","toolCallId":"a","name":"read","arguments":{},"groupId":"stream:turn:tool-group:0","groupIndex":0,"groupCount":3,"groupFinalized":true},
            {"id":"stream:turn:1","ordinal":1,"type":"toolCall","toolCallId":"b","name":"bash","arguments":{},"groupId":"stream:turn:tool-group:0","groupIndex":1,"groupCount":3,"groupFinalized":true},
            {"id":"stream:turn:2","ordinal":2,"type":"toolCall","toolCallId":"c","name":"edit","arguments":{},"groupId":"stream:turn:tool-group:0","groupIndex":2,"groupCount":3,"groupFinalized":true}
          ]}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = [
            tool("a", "read", startedAt: "2026-01-01T00:00:01Z", order: 0, groupId: "stream:turn:tool-group:0", groupIndex: 0, groupCount: 3),
            tool("b", "bash", startedAt: "2026-01-01T00:00:01Z", order: 1, groupId: "stream:turn:tool-group:0", groupIndex: 1, groupCount: 3),
            tool("c", "edit", startedAt: "2026-01-01T00:00:01Z", order: 2, groupId: "stream:turn:tool-group:0", groupIndex: 2, groupCount: 3),
        ]

        guard case .toolRun(let running) = ChatTranscriptPresentation.timeline(in: snapshot).items.first else {
            Issue.record("Expected finalized tool group")
            return
        }
        #expect(running.id == "tool-run-stream:turn:tool-group:0")
        #expect(running.tools.map(\.id) == ["a", "b", "c"])
        #expect(running.title == "Using 3 tools")

        snapshot.toolExecutions = snapshot.toolExecutions.map {
            tool($0.toolCallId, $0.toolName, status: .completed, startedAt: $0.startedAt,
                 order: $0.order, groupId: $0.groupId, groupIndex: $0.groupIndex, groupCount: $0.groupCount)
        }
        guard case .toolRun(let completed) = ChatTranscriptPresentation.timeline(in: snapshot).items.first else {
            Issue.record("Expected completed tool group")
            return
        }
        #expect(completed.id == running.id)
        #expect(completed.title == "Used 3 tools")
    }

    @Test("interaction and editor presentation use deterministic priority")
    func extensionPresentationArbiterPriority() {
        #expect(ChatExtensionPresentationArbiter.presentation(
            modelSettled: false, hasInteraction: true, hasEditorRequest: true
        ) == .none)
        #expect(ChatExtensionPresentationArbiter.presentation(
            modelSettled: true, hasInteraction: true, hasEditorRequest: true
        ) == .interaction)
        #expect(ChatExtensionPresentationArbiter.presentation(
            modelSettled: true, hasInteraction: false, hasEditorRequest: true
        ) == .editorRequest)
        #expect(ChatExtensionPresentationArbiter.presentation(
            modelSettled: true, hasInteraction: false, hasEditorRequest: false
        ) == .none)
    }

    @Test("extreme frame colors fall back when contrast is unreadable")
    func extensionFrameContrastPolicy() {
        #expect(ExtensionFrameColorPolicy.contrastRatio("000000", "FFFFFF") > 20)
        #expect(ExtensionFrameColorPolicy.contrastRatio("000000", "000000") < 1.1)
        #expect(ExtensionFrameColorPolicy.usableForeground("000000", background: "000000", fallback: "FFFFFF") == "FFFFFF")
        #expect(ExtensionFrameColorPolicy.usableBackground("FFFFFF", foreground: "FFFFFF", fallback: "16181D") == "16181D")
    }

    @Test("inverse frame colors resolve as one contrast-checked swapped pair")
    func inverseFrameColorsRemainReadable() {
        let colors = ExtensionFrameColorPolicy.resolvedColors(
            foreground: "FFFFFF",
            background: "FFFFFF",
            inverse: true,
            nativeForeground: "F8FAFC",
            nativeBackground: "090A0C",
            fallbackBackground: "16181D"
        )
        #expect(colors.foreground == "FFFFFF")
        #expect(colors.background == "16181D")
        #expect(ExtensionFrameColorPolicy.contrastRatio(colors.foreground, colors.background) >= ExtensionFrameColorPolicy.minimumContrast)
        let defaults = ExtensionFrameColorPolicy.resolvedColors(
            foreground: nil,
            background: nil,
            inverse: true,
            nativeForeground: "F8FAFC",
            nativeBackground: "090A0C",
            fallbackBackground: "16181D"
        )
        #expect(defaults.foreground == "090A0C")
        #expect(defaults.background == "F8FAFC")
    }

    @Test("interaction suppression is exact-scope and queue-safe")
    func interactionSuppressionScope() {
        let first = ExtensionInteraction(id: "first", hostEpoch: "epoch", presentationRevision: 4, method: .select, title: "First", options: ["A"])
        let newer = ExtensionInteraction(id: "newer", hostEpoch: "epoch", presentationRevision: 5, method: .input, title: "Newer")
        let replacement = ExtensionInteraction(id: "first", hostEpoch: "epoch", presentationRevision: 6, method: .select, title: "Replacement", options: ["B"])
        let nextEpoch = ExtensionInteraction(id: "first", hostEpoch: "next", presentationRevision: 1, method: .select, title: "Next", options: ["C"])
        let scope = ExtensionInteractionScope(first)

        #expect(ChatExtensionInteractionPolicy.presentedInteraction([first], suppressing: scope) == nil)
        #expect(ChatExtensionInteractionPolicy.presentedInteraction([first, newer], suppressing: scope) == newer)
        #expect(ChatExtensionInteractionPolicy.presentedInteraction([replacement], suppressing: scope) == replacement)
        #expect(ChatExtensionInteractionPolicy.presentedInteraction([nextEpoch], suppressing: scope) == nextEpoch)
        #expect(!ChatExtensionInteractionPolicy.shouldClearSuppression(scope, from: [first, newer]))
        #expect(ChatExtensionInteractionPolicy.shouldClearSuppression(scope, from: [replacement]))
        #expect(ChatExtensionInteractionPolicy.shouldClearSuppression(scope, from: []))
    }

    @Test("failed interaction responses do not create suppression scope")
    func failedInteractionResponseLeavesScopeAvailable() {
        let interaction = ExtensionInteraction(id: "failed", hostEpoch: "epoch", presentationRevision: 2, method: .confirm, title: "Continue?")
        #expect(ChatExtensionInteractionPolicy.presentedInteraction([interaction], suppressing: nil) == interaction)
    }

    @Test("queued compaction is explicit until canonical compaction starts")
    func queuedCompactionPresentation() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.compactionQueued = true
        snapshot.extensionPresentation.semanticState.working = .init(message: nil, visible: true)

        let queued = ChatNotificationPresentation.runtime(in: snapshot)
        #expect(queued.map(\.id) == ["runtime-compaction-queued"])
        #expect(queued.first?.title == "Compaction queued")
        #expect(queued.first?.detail == "After current work")
        #expect(queued.first?.semanticID == nil)
        #expect(queued.first?.material == .flat)

        snapshot.compactionQueued = false
        snapshot.phase = .compacting
        let active = ChatNotificationPresentation.runtime(in: snapshot)
        #expect(active.count == 1)
        #expect(active.first?.title == "Compacting context")
        #expect(active.first?.id == "runtime-working")
    }

    @Test("exact canonical compaction suppresses queued and active overlap through trailing metadata")
    func canonicalCompactionOverlapSuppression() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"compact","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"done","tokensBefore":100},
          {"id":"model","parentId":"compact","timestamp":"2026-01-01T00:00:01Z","kind":"modelChange","modelRef":{"provider":"openai","id":"next"}},
          {"id":"thinking","parentId":"model","timestamp":"2026-01-01T00:00:02Z","kind":"thinkingChange","level":"high"},
          {"id":"label","parentId":"thinking","timestamp":"2026-01-01T00:00:03Z","kind":"label","targetId":"compact","label":"checkpoint"}
        ]
        """)
        snapshot.phase = .compacting
        snapshot.compactionQueued = true
        snapshot.extensionPresentation.semanticState.working = .init(message: nil, visible: true)
        snapshot.transcriptStart = 8
        snapshot.transcriptTotal = 12

        #expect(ChatNotificationPresentation.runtime(in: snapshot).isEmpty)

        snapshot.transcriptTotal = 13
        #expect(ChatNotificationPresentation.runtime(in: snapshot).map(\.id) == [
            "runtime-compaction-queued", "runtime-working",
        ])
    }

    @Test("pending prompts retain their requested delivery label across reconstruction")
    func pendingPromptPresentation() {
        let steer = ChatPendingPromptPresentation(snapshot: .init(
            id: "pending-steer",
            createdAt: "2026-01-01T00:00:00Z",
            behavior: .steer,
            text: "wait for compaction",
            attachmentCount: 0
        ), isCompacting: true)
        #expect(steer.statusTitle == "Steering after compaction")
        #expect(steer.text == "wait for compaction")

        let ordinary = ChatPendingPromptPresentation(snapshot: .init(
            id: "pending-prompt",
            createdAt: "2026-01-01T00:00:00Z",
            behavior: nil,
            text: "send after compaction",
            attachmentCount: 1
        ), isCompacting: false)
        #expect(ordinary.statusTitle == "Sending")
        #expect(ordinary.promptBehavior == .ordinary)
        #expect(ordinary.attachmentCount == 1)

        let preflightCompacting = ChatPendingPromptPresentation(snapshot: .init(
            id: "pending-preflight",
            createdAt: "2026-01-01T00:00:00Z",
            behavior: nil,
            text: "next after compaction",
            attachmentCount: 0
        ), isCompacting: true)
        #expect(preflightCompacting.promptBehavior == .ordinary)
        #expect(preflightCompacting.usesQueuedCardVisual)
        #expect(preflightCompacting.cardBehavior == .steer)
        #expect(preflightCompacting.cardTitle == "Message")
        #expect(preflightCompacting.cardDetail == "After compaction")
        #expect(preflightCompacting.statusTitle == "Sending after compaction")
    }

    @Test("optimistic submissions preserve steering identity before Gateway reconstruction")
    func outgoingSubmissionPresentation() {
        let target = SessionPresentationIdentity(sessionID: "session", generation: 3)
        let steer = ChatOutgoingSubmissionPresentation(
            snapshot: ComposerSubmissionSnapshot(
                target: target,
                textRevision: 4,
                outgoingText: String(repeating: "large prompt ", count: 100),
                attachmentIDs: ["photo"],
                behavior: "steer",
                localNonce: 4
            ),
            transportActive: true
        )
        #expect(steer.statusTitle == "Steering next")
        #expect(steer.attachmentIDs == ["photo"])
        #expect(steer.transportActive)
    }

    @Test("ordinary running state uses canonical phase activity without extension chrome")
    func ordinaryRunningUsesAmbientActivity() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.retry = nil
        snapshot.extensionPresentation.semanticState.working = .init(
            message: "Retired extension status",
            visible: false
        )

        let presentation = try #require(ChatRuntimeWorkingPresentation(
            phase: snapshot.phase,
            retry: snapshot.retry
        ))
        #expect(presentation.message == "Tron is working")
        #expect(presentation.usesAmbientBottomIndicator)
        #expect(ChatNotificationPresentation.runtime(in: snapshot).isEmpty)
    }

    @Test("runtime working presentation follows canonical phase and retry only")
    func runtimeWorkingRowPolicy() {
        let retry = RetryState(
            source: .agent,
            attempt: 2,
            maxAttempts: 4,
            delayMs: 500,
            errorMessage: "transient"
        )
        let running = ChatRuntimeWorkingPresentation(phase: .running, retry: nil)
        #expect(running?.message == "Tron is working")
        #expect(running?.usesAmbientBottomIndicator == true)

        let compacting = ChatRuntimeWorkingPresentation(phase: .compacting, retry: nil)
        #expect(compacting?.message == "Compacting context")
        #expect(compacting?.usesAmbientBottomIndicator == false)

        let retrying = ChatRuntimeWorkingPresentation(phase: .retrying, retry: retry)
        #expect(retrying?.message == "Retrying provider")
        #expect(retrying?.retryMessage == "Attempt 2 of 4")
        #expect(retrying?.usesAmbientBottomIndicator == false)

        #expect(ChatRuntimeWorkingPresentation(phase: .idle, retry: nil) == nil)
        #expect(ChatRuntimeWorkingPresentation(phase: .interrupted, retry: retry) == nil)
    }

    @Test("zero and partial geometry never masquerade as bottom readiness")
    func chatGeometryValidity() {
        #expect(!ChatTranscriptGeometry.zero.isValid)
        #expect(!ChatTranscriptGeometry.zero.isAtExactBottom)
        let partial = ChatTranscriptGeometry(offsetY: 0, contentHeight: 100, containerHeight: 0)
        #expect(!partial.isValid)
        #expect(!partial.isAtBottom)
        let ready = ChatTranscriptGeometry(offsetY: 400, contentHeight: 800, containerHeight: 400)
        #expect(ready.isValid)
        #expect(ready.isAtExactBottom)

        let insetBottom = ChatTranscriptGeometry(
            offsetY: 472, contentHeight: 800, containerHeight: 400, bottomInset: 72
        )
        let insetAway = ChatTranscriptGeometry(
            offsetY: 372, contentHeight: 800, containerHeight: 400, bottomInset: 72
        )
        #expect(insetBottom.isAtExactBottom)
        #expect(insetBottom.isAtCatchUpBoundary)
        #expect(insetAway.distanceFromBottom == 100)
        #expect(!insetAway.isAtBottom)
        let roundedTail = ChatTranscriptGeometry(
            offsetY: 460, contentHeight: 800, containerHeight: 400, bottomInset: 72
        )
        #expect(!roundedTail.isAtExactBottom)
        #expect(roundedTail.isAtCatchUpBoundary)
    }

    @Test("chat toolbar title remains bounded during interactive navigation")
    func toolbarTitleWidth() {
        #expect(ChatToolbarTitleLayout.width(containerWidth: 0) == 80)
        #expect(ChatToolbarTitleLayout.width(containerWidth: 402) == 250)
        #expect(ChatToolbarTitleLayout.width(containerWidth: 440) == 288)
        #expect(ChatToolbarTitleLayout.width(containerWidth: 1_024) == 360)
    }

    @Test("attachment menu availability is session scoped and independent of draft text")
    func attachmentAvailability() {
        #expect(!ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: false, phase: .idle, isSending: false
        ))
        #expect(!ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: nil, isSending: false
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .running, isSending: false
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .idle, isSending: true
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .idle, isSending: false
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .interrupted, isSending: false
        ))

        let running = ChatAttachmentMenuState(
            sessionID: "session", phase: .running,
            isTranscriptReady: true, isSending: false
        )
        let compacting = ChatAttachmentMenuState(
            sessionID: "session", phase: .compacting,
            isTranscriptReady: true, isSending: false
        )
        let idle = ChatAttachmentMenuState(
            sessionID: "session", phase: .idle,
            isTranscriptReady: true, isSending: false
        )
        let anotherIdle = ChatAttachmentMenuState(
            sessionID: "another-session", phase: .idle,
            isTranscriptReady: true, isSending: false
        )
        #expect(running.actionsEnabled)
        #expect(idle.actionsEnabled)
        #expect(running.identity == compacting.identity)
        #expect(running.identity == idle.identity)
        #expect(idle.identity != anotherIdle.identity)
    }

    @Test("authoritative sync remains covered until the physical viewport is positioned")
    func chatOpenPresentationState() {
        var state = ChatOpenPresentationState(sessionID: "session-a")
        let epoch = state.begin()
        let wrongSession = state.installAuthoritativeBaseline(sessionID: "session-b", epoch: epoch)
        let staleEpoch = state.installAuthoritativeBaseline(sessionID: "session-a", epoch: epoch - 1)
        #expect(!wrongSession)
        #expect(!staleEpoch)
        #expect(state.phase == .opening)

        let installed = state.installAuthoritativeBaseline(sessionID: "session-a", epoch: epoch)
        #expect(installed)
        #expect(state.phase == .positioning)
        let wrongPositionedSession = state.installPositionedViewport(
            sessionID: "session-b", epoch: epoch
        )
        let stalePositionedEpoch = state.installPositionedViewport(
            sessionID: "session-a", epoch: epoch - 1
        )
        let positioned = state.installPositionedViewport(sessionID: "session-a", epoch: epoch)
        #expect(!wrongPositionedSession)
        #expect(!stalePositionedEpoch)
        #expect(positioned)
        #expect(state.phase == .ready)
    }

    @Test("stale presentation callbacks cannot fail a newer opening epoch")
    func staleChatOpenCallbacks() {
        var state = ChatOpenPresentationState(sessionID: "session-a")
        let staleEpoch = state.begin()
        let currentEpoch = state.begin()
        let stale = state.fail(sessionID: "session-a", epoch: staleEpoch, message: "stale")
        let wrongSession = state.fail(sessionID: "session-b", epoch: currentEpoch, message: "wrong session")
        #expect(!stale)
        #expect(!wrongSession)
        #expect(state.phase == .opening)
        let failed = state.fail(sessionID: "session-a", epoch: currentEpoch, message: "offline")
        #expect(failed)
        #expect(state.phase == .failed("offline"))
    }

    @Test("earlier page responses require the exact mounted generation and cursor")
    func earlierPageRequestIdentity() {
        let request = ChatTranscriptPageRequest(
            sessionID: "session-a",
            presentationGeneration: 7,
            runtimeGeneration: "runtime-a",
            before: 40,
            expectedTotal: 48,
            expectedNextEntryID: "entry-40"
        )
        #expect(request.canInstall(
            sessionID: "session-a", presentationGeneration: 7,
            runtimeGeneration: "runtime-a", transcriptStart: 40,
            transcriptTotal: 48, firstTranscriptID: "entry-40"
        ))
        #expect(!request.canInstall(
            sessionID: "session-a", presentationGeneration: 7,
            runtimeGeneration: "runtime-a", transcriptStart: 40,
            transcriptTotal: nil, firstTranscriptID: "entry-40"
        ))
        #expect(!request.canInstall(
            sessionID: "session-a", presentationGeneration: 8,
            runtimeGeneration: "runtime-a", transcriptStart: 40,
            transcriptTotal: 48, firstTranscriptID: "entry-40"
        ))
        #expect(!request.canInstall(
            sessionID: "session-a", presentationGeneration: 7,
            runtimeGeneration: "runtime-a", transcriptStart: 20,
            transcriptTotal: 48, firstTranscriptID: "entry-20"
        ))
        let maximum = ChatTranscriptPageRequest(
            sessionID: "session-a",
            presentationGeneration: 7,
            runtimeGeneration: "runtime-a",
            before: Int.max,
            expectedTotal: Int.max,
            expectedNextEntryID: nil
        )
        #expect(!maximum.canInstallPage(
            start: Int.max - 1,
            end: Int.max,
            total: Int.max,
            itemCount: 1,
            visibleItemCount: 1
        ))
    }

    @Test("bootstrap configuration stays in Manage Session")
    func hidesBootstrapConfiguration() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"model","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"gpt-5.6-sol"}},
          {"id":"thinking","parentId":"model","timestamp":"2026-01-01T00:00:01Z","kind":"thinkingChange","level":"high"},
          {"id":"user","parentId":"thinking","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"hello"}]}
        ]
        """)

        #expect(ChatTranscriptPresentation.items(in: snapshot).map(\.id) == ["user"])
    }

    @Test("configuration changes after conversation begins remain notifications")
    func retainsLaterChanges() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"hello"}]},
          {"id":"model","parentId":"user","timestamp":"2026-01-01T00:00:01Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"gpt-5.6-sol"}},
          {"id":"thinking","parentId":"model","timestamp":"2026-01-01T00:00:02Z","kind":"thinkingChange","level":"high"}
        ]
        """)

        #expect(ChatTranscriptPresentation.items(in: snapshot).map(\.id) == ["user", "model", "thinking"])
    }

    @Test("initial hydration and session changes do not manufacture unread responses")
    func unreadBaselinePolicy() throws {
        let first = ChatResponseState(snapshot: try fixture(transcript: "[]"))
        #expect(!ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: nil,
            current: first,
            userScrolledAway: true
        ))

        var switchedSnapshot = try fixture(transcript: "[]")
        switchedSnapshot.sessionId = "another-session"
        #expect(!ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: first,
            current: ChatResponseState(snapshot: switchedSnapshot),
            userScrolledAway: true
        ))
    }

    @Test("unread observation ignores tool and runtime status while retaining response facts")
    func unreadObservationEquality() throws {
        var snapshot = try fixture(transcript: "[]")
        let baseline = ChatResponseState(snapshot: snapshot)

        snapshot.phase = .running
        snapshot.toolExecutions = [tool("call", "read", startedAt: "2026-01-01T00:00:00Z")]
        snapshot.extensionPresentation.semanticState.statuses = ["provider": "Working"]
        #expect(ChatResponseState(snapshot: snapshot) == baseline)

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"call","name":"read","arguments":{"path":"one"}}]}
        """)
        let toolOnly = ChatResponseState(snapshot: snapshot)
        #expect(toolOnly == baseline)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"call","name":"read","arguments":{"path":"two"}}]}
        """)
        #expect(ChatResponseState(snapshot: snapshot) == toolOnly)

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"text","type":"text","text":"hello"}]}
        """)
        #expect(ChatResponseState(snapshot: snapshot) != baseline)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"thinking","type":"thinking","text":"considering"}]}
        """)
        #expect(ChatResponseState(snapshot: snapshot) != baseline)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"image","type":"image","mimeType":"image/png","blobId":"blob"}]}
        """)
        #expect(ChatResponseState(snapshot: snapshot) != baseline)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[],"errorMessage":"failed"}
        """)
        #expect(ChatResponseState(snapshot: snapshot) != baseline)

        snapshot.streaming = nil
        snapshot.transcript = try transcript("""
        [{"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"text","type":"text","text":"hello"}]}]
        """)
        snapshot.transcriptTotal = 1
        #expect(ChatResponseState(snapshot: snapshot) != baseline)
    }

    @Test("new response marks unread only while scrolled away")
    func unreadResponsePolicy() throws {
        let previous = ChatResponseState(snapshot: try fixture(transcript: "[]"))
        let updated = ChatResponseState(snapshot: try fixture(transcript: """
        [{"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"assistant:0","type":"text","text":"hello"}]}]
        """))
        #expect(ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: previous,
            current: updated,
            userScrolledAway: true
        ))
        #expect(!ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: previous,
            current: updated,
            userScrolledAway: false
        ))
    }

    @Test("tool run identity follows authoritative order rather than opaque ID sorting")
    func toolRunIdentityUsesAuthoritativeOrder() {
        let ordered = ChatToolRunPresentation(tools: [
            toolPresentation("opaque-z-first"),
            toolPresentation("opaque-a-second"),
        ])
        #expect(ordered.id == "tool-run-opaque-z-first")
    }

    @Test("tool detail rows are reverse chronological with stable source fallback")
    func reverseChronologicalToolDetails() {
        let run = ChatToolRunPresentation(tools: [
            toolPresentation("old", startedAt: "2026-01-01T00:00:01Z").descriptor,
            toolPresentation("new", startedAt: "2026-01-01T00:00:03Z").descriptor,
            toolPresentation("latest-without-timestamp").descriptor,
            toolPresentation("middle", startedAt: "2026-01-01T00:00:02Z").descriptor,
        ])

        #expect(run.reverseChronologicalTools.map(\.id) == [
            "middle", "latest-without-timestamp", "new", "old",
        ])
        #expect(ChatToolInvocationOrdering.reverseChronological([
            toolPresentation("old", startedAt: "2026-01-01T00:00:01Z"),
            toolPresentation("new", startedAt: "2026-01-01T00:00:03Z"),
        ]).map(\.id) == ["new", "old"])
    }

    @Test("compaction token counts use compact K shorthand")
    func compactCompactionTokenCounts() {
        #expect(ChatTokenCountPresentation.beforeCompaction(0) == "0 tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(1) == "1 token before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(999) == "999 tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(1_000) == "1K tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(12_300) == "12.3K tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(322_486) == "322K tokens before compaction")
    }

    @Test("notification policy separates flat status from detail-bearing summaries")
    func notificationMaterialPolicy() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"compact","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"Condensed context","tokensBefore":1200},
          {"id":"model","parentId":"compact","timestamp":"2026-01-01T00:00:01Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"gpt-5.6-sol"}}
        ]
        """)
        let compact = try #require(ChatNotificationPresentation.canonical(snapshot.transcript[0], globalOrdinal: 8))
        let model = try #require(ChatNotificationPresentation.canonical(snapshot.transcript[1], globalOrdinal: 9))

        #expect(compact.id == "notification-compaction-slot-8")
        #expect(compact.material == .glass)
        #expect(compact.hasDetailSheet)
        #expect(compact.tone == .accent)
        #expect(model.material == .flat)
        #expect(!model.hasDetailSheet)
        #expect(model.detail == "OpenAI Codex / GPT 5.6 Sol")
    }

    @Test("whitespace-only summaries stay flat and noninteractive")
    func whitespaceSummaryIsFlat() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"blank","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"  \\n  ","tokensBefore":1200}
        ]
        """)
        let notification = try #require(
            ChatNotificationPresentation.canonical(snapshot.transcript[0], globalOrdinal: 0)
        )
        #expect(notification.body == nil)
        #expect(notification.material == .flat)
        #expect(!notification.hasDetailSheet)
    }

    @Test("pending compaction operation identity survives inexact tail bounds")
    func pendingCompactionContinuity() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .compacting
        snapshot.operation = .init(
            id: "compaction-operation", kind: .compaction,
            startedAt: "2026-01-01T00:00:00Z", reason: "threshold"
        )
        snapshot.extensionPresentation.semanticState.working = .init(message: nil, visible: true)
        snapshot.transcriptStart = 7
        snapshot.transcriptTotal = 7
        let exact = try #require(ChatNotificationPresentation.runtime(in: snapshot).first)
        #expect(exact.id == "notification-compaction-operation-compaction-operation")
        #expect(exact.title == "Compacting context")
        #expect(exact.material == .flat)

        snapshot.transcriptTotal = 8
        let malformed = try #require(ChatNotificationPresentation.runtime(in: snapshot).first)
        #expect(malformed.id == exact.id)

        snapshot.transcriptStart = Int.max
        snapshot.transcriptTotal = Int.max
        snapshot.transcript = [try fixture(transcript: """
        [{"id":"user-max","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"x"}]}]
        """).transcript[0]]
        let maximum = try #require(ChatNotificationPresentation.runtime(in: snapshot).first)
        #expect(maximum.id == exact.id)
    }

    @Test("canonical compaction keeps its live operation presentation identity")
    func canonicalCompactionOperationIdentity() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"compact","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","presentationId":"compaction-operation","summary":"A","tokensBefore":100}
        ]
        """)
        let notification = try #require(
            ChatNotificationPresentation.canonical(snapshot.transcript[0], globalOrdinal: 9)
        )
        #expect(notification.id == "notification-compaction-operation-compaction-operation")
        #expect(notification.semanticID == "compact")
        #expect(throws: DecodingError.self) {
            try fixture(transcript: """
            [
              {"id":"invalid","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","presentationId":"","summary":"A"}
            ]
            """)
        }
    }

    @Test("canonical compaction ordinals survive bounded tails and prepends")
    func canonicalCompactionOrdinals() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"compact-a","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"A","tokensBefore":100},
          {"id":"compact-b","parentId":"compact-a","timestamp":"2026-01-01T00:00:01Z","kind":"compaction","summary":"B","tokensBefore":200}
        ]
        """)
        snapshot.transcriptStart = 5
        snapshot.transcriptTotal = 7
        let notifications = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> ChatNotificationPresentation? in
            guard case .notification(let notification) = item else { return nil }
            return notification
        }
        #expect(notifications.map(\.id) == [
            "notification-compaction-slot-5", "notification-compaction-slot-6",
        ])

        snapshot.transcriptStart = 3
        snapshot.transcript.insert(contentsOf: try fixture(transcript: """
        [
          {"id":"older-a","parentId":null,"timestamp":"2025-12-31T23:59:58Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"older"}},
          {"id":"older-b","parentId":"older-a","timestamp":"2025-12-31T23:59:59Z","kind":"thinkingChange","level":"low"}
        ]
        """).transcript, at: 0)
        let prepended = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> ChatNotificationPresentation? in
            guard case .notification(let notification) = item,
                  notification.id.hasPrefix("notification-compaction-slot") else { return nil }
            return notification
        }
        #expect(prepended.map(\.id) == notifications.map(\.id))

        snapshot.transcriptTotal = 99
        let malformed = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> String? in
            guard case .notification(let notification) = item,
                  notification.semanticID?.hasPrefix("compact-") == true else { return nil }
            return notification.id
        }
        #expect(malformed == [
            "notification-compaction-compact-a", "notification-compaction-compact-b",
        ])
    }

    @Test("duplicate canonical IDs remain invalid without ordinal construction trap")
    func duplicateCompactionIDsFailSafe() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"duplicate","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"A","tokensBefore":100},
          {"id":"duplicate","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"compaction","summary":"B","tokensBefore":200}
        ]
        """)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 2
        let ids = ChatTranscriptPresentation.timeline(in: snapshot).items.map(\.id)
        #expect(ids == [
            "notification-compaction-duplicate",
            "notification-compaction-duplicate",
        ])
    }

    @Test("prompt images and files share one attachment strip above text")
    func promptAttachmentStrip() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[
            {"id":"user:0","type":"text","text":"What about these?"},
            {"id":"user:1","type":"image","mimeType":"image/jpeg","blobId":"photo"},
            {"id":"user:2","type":"text","text":"notes.pdf","attachment":{"name":"notes.pdf","mimeType":"application/pdf","size":2048}}
          ]}
        ]
        """)
        let item = try #require(snapshot.transcript.first)
        let attachments = ChatTranscriptPresentation.attachmentParts(in: item)
        #expect(attachments.map(\.type) == [.image, .text])
        #expect(attachments.last?.attachment?.name == "notes.pdf")
        #expect(attachments.last?.attachment?.size == 2048)
    }

    @Test("consecutive thinking lines become one complete inline run")
    func groupsConsecutiveThinkingLines() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"  Inspecting the transcript  \\nChecking spacing..."},
            {"id":"thinking-2","type":"thinking","text":"Confirming   the grouped lines…\\n..."},
            {"id":"answer","type":"text","text":"Done"}
          ]}
        ]
        """)
        let item = try #require(snapshot.transcript.first)
        let parts = ChatTranscriptPresentation.messageParts(in: item)

        #expect(parts.count == 2)
        guard case .thinking(let run) = parts[0] else {
            Issue.record("Expected one thinking run")
            return
        }
        #expect(run.id == "thinking-1")
        #expect(run.segments.map(\.id) == [
            "thinking-1:line:0",
            "thinking-1:line:1",
            "thinking-2:line:0",
            "thinking-2:line:1",
        ])
        #expect(run.segments.map(\.text) == [
            "Inspecting the transcript",
            "Checking spacing...",
            "Confirming the grouped lines…",
            "...",
        ])
        guard case .content(let answer) = parts[1] else {
            Issue.record("Expected answer after thinking")
            return
        }
        #expect(answer.id == "answer")
    }

    @Test("content boundaries keep thinking runs separate and stable")
    func thinkingRunBoundaries() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"First"},
            {"id":"call","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{}},
            {"id":"thinking-empty","type":"thinking","text":"  \\n  "},
            {"id":"thinking-2","type":"thinking","text":"Second"}
          ]}
        ]
        """)
        let item = try #require(snapshot.transcript.first)
        let parts = ChatTranscriptPresentation.messageParts(in: item)

        #expect(parts.map(\.id) == ["thinking-thinking-1", "content-call", "thinking-thinking-2"])
        guard case .thinking(let trailingRun) = parts[2] else {
            Issue.record("Expected trailing thinking run")
            return
        }
        #expect(trailingRun.segments.map(\.id) == ["thinking-2:line:0"])
        #expect(trailingRun.segments.map(\.text) == ["Second"])
    }

    @Test("timeline preserves thinking around an intervening tool")
    func preservesThinkingToolOrder() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"First"},
            {"id":"call","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{}},
            {"id":"thinking-2","type":"thinking","text":"Second"}
          ]}
        ]
        """)
        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let timeline = candidate.timeline

        #expect(timeline.ids == [
            "assistant",
            "tool-run-call-1",
            "assistant-slice-thinking-thinking-2",
        ])
        guard case .message(let first) = timeline.items[0],
              case .thinking(let firstRun) = first.parts.first,
              case .toolRun(let toolRun) = timeline.items[1],
              case .message(let last) = timeline.items[2],
              case .thinking(let lastRun) = last.parts.first else {
            Issue.record("Expected thinking slices around the tool run")
            return
        }
        #expect(firstRun.segments.map(\.text) == ["First"])
        let detail = try #require(toolRun.tools.first.flatMap(candidate.toolPayloads.resolving))
        #expect(detail.content == "")
        #expect(detail.request == .object([:]))
        #expect(detail.fallbackContent == .object([:]))
        #expect(lastRun.segments.map(\.text) == ["Second"])
    }

    @Test("thinking barriers preserve exact order across multiple consolidated tool runs")
    func thinkingBarriersPreserveToolOrder() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"First"},
            {"id":"call-1","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{}},
            {"id":"call-2","type":"toolCall","toolCallId":"call-2","name":"read","arguments":{}},
            {"id":"thinking-2","type":"thinking","text":"Between"},
            {"id":"call-3","type":"toolCall","toolCallId":"call-3","name":"bash","arguments":{}},
            {"id":"thinking-3","type":"thinking","text":"Last"}
          ]}
        ]
        """)
        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)

        #expect(timeline.ids == [
            "assistant",
            "tool-run-call-1",
            "assistant-slice-thinking-thinking-2",
            "tool-run-call-3",
            "assistant-slice-thinking-thinking-3",
        ])
        guard case .toolRun(let firstRun) = timeline.items[1],
              case .message(let between) = timeline.items[2],
              case .thinking(let betweenThinking) = between.parts.first,
              case .toolRun(let secondRun) = timeline.items[3] else {
            Issue.record("Expected thinking to split canonical tool runs")
            return
        }
        #expect(firstRun.tools.map(\.id) == ["call-1", "call-2"])
        #expect(betweenThinking.segments.map(\.text) == ["Between"])
        #expect(secondRun.tools.map(\.id) == ["call-3"])
    }

    @Test("consecutive tool calls collapse into one presentation run")
    func groupsConsecutiveToolCalls() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part-1","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{"path":"one"},"toolSegmentId":"tool-segment:turn"}]},
          {"id":"result-1","parentId":"assistant-1","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text-1","type":"text","text":"one"}],"toolCallId":"call-1","toolName":"read","isError":false},
          {"id":"assistant-2","parentId":"result-1","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-part-2","type":"toolCall","toolCallId":"call-2","name":"bash","arguments":{"command":"pwd"},"toolSegmentId":"tool-segment:turn"}]},
          {"id":"result-2","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"result-text-2","type":"text","text":"/workspace"}],"toolCallId":"call-2","toolName":"bash","isError":false}
        ]
        """)

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let timeline = candidate.timeline
        let rendered = timeline.items
        #expect(rendered.count == 1)
        guard case .toolRun(let run) = rendered.first else {
            Issue.record("Expected one grouped tool run")
            return
        }
        #expect(run.tools.map(\.title) == ["read", "bash"])
        let details = run.tools.compactMap(candidate.toolPayloads.resolving)
        #expect(details[0].request == .object(["path": .string("one")]))
        #expect(details[0].response == nil)
        #expect(details[1].request == .object(["command": .string("pwd")]))
        #expect(run.title == "Used 2 tools")
        #expect(timeline.preferredSemanticIDByRenderedID[run.id] == "call-2")
        #expect(timeline.renderedIDBySemanticID["call-1"] == run.id)
        #expect(timeline.renderedIDBySemanticID["call-2"] == run.id)
    }

    @Test("finalized tool-only groups coalesce across canonical results")
    func finalizedToolOnlyGroupsCoalesce() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"a","ordinal":0,"type":"toolCall","toolCallId":"a","name":"read","arguments":{},"toolSegmentId":"tool-segment:turn","groupId":"group-1","groupIndex":0,"groupCount":2,"groupFinalized":true},
            {"id":"b","ordinal":1,"type":"toolCall","toolCallId":"b","name":"bash","arguments":{},"toolSegmentId":"tool-segment:turn","groupId":"group-1","groupIndex":1,"groupCount":2,"groupFinalized":true}
          ]},
          {"id":"result-a","parentId":"assistant-1","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"ra","ordinal":0,"type":"text","text":"a"}],"toolCallId":"a","toolName":"read","isError":false},
          {"id":"result-b","parentId":"result-a","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"rb","ordinal":0,"type":"text","text":"b"}],"toolCallId":"b","toolName":"bash","isError":false},
          {"id":"assistant-2","parentId":"result-b","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[
            {"id":"c","ordinal":0,"type":"toolCall","toolCallId":"c","name":"edit","arguments":{},"toolSegmentId":"tool-segment:turn","groupId":"group-2","groupIndex":0,"groupCount":1,"groupFinalized":true}
          ]},
          {"id":"result-c","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"rc","ordinal":0,"type":"text","text":"c"}],"toolCallId":"c","toolName":"edit","isError":false}
        ]
        """)

        let runs = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.count == 1)
        #expect(runs.first?.tools.map(\.id) == ["a", "b", "c"])
        #expect(runs.first?.anchorID == "group-1")
        #expect(runs.first?.title == "Used 3 tools")
    }

    @Test("visible thinking is a hard barrier between finalized tool groups")
    func thinkingSeparatesFinalizedToolGroups() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"a","ordinal":0,"type":"toolCall","toolCallId":"a","name":"read","arguments":{},"groupId":"group-1","groupIndex":0,"groupCount":1,"groupFinalized":true}
          ]},
          {"id":"result-a","parentId":"assistant-1","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"ra","ordinal":0,"type":"text","text":"a"}],"toolCallId":"a","toolName":"read","isError":false},
          {"id":"assistant-2","parentId":"result-a","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[
            {"id":"thinking","ordinal":0,"thinkingRunOrdinal":0,"type":"thinking","text":"Planning the edit"},
            {"id":"b","ordinal":1,"type":"toolCall","toolCallId":"b","name":"edit","arguments":{},"toolSegmentId":"tool-segment:turn","groupId":"group-2","groupIndex":0,"groupCount":1,"groupFinalized":true}
          ]},
          {"id":"result-b","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"rb","ordinal":0,"type":"text","text":"b"}],"toolCallId":"b","toolName":"edit","isError":false}
        ]
        """)

        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)
        let runs = timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.map { $0.tools.map(\.id) } == [["a"], ["b"]])
        #expect(timeline.items.contains { item in
            guard case .message(let message) = item else { return false }
            return message.parts.contains { part in
                guard case .thinking = part else { return false }
                return true
            }
        })
    }

    @Test("page prepend reanchors one adjacent tool display run without losing calls")
    func semanticAnchorSurvivesPageBoundaryRegrouping() throws {
        let current = try fixture(transcript: """
        [
          {"id":"assistant-2","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-part-2","type":"toolCall","toolCallId":"call-2","name":"bash","arguments":{"command":"pwd"},"toolSegmentId":"tool-segment:turn"}]},
          {"id":"result-2","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"result-text-2","type":"text","text":"/workspace"}],"toolCallId":"call-2","toolName":"bash","isError":false}
        ]
        """)
        let before = ChatTranscriptPresentation.timeline(in: current)
        #expect(before.ids == ["tool-run-call-2"])
        #expect(before.preferredSemanticIDByRenderedID["tool-run-call-2"] == "call-2")

        let prepended = try fixture(transcript: """
        [
          {"id":"assistant-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part-1","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{"path":"one"},"toolSegmentId":"tool-segment:turn"}]},
          {"id":"result-1","parentId":"assistant-1","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text-1","type":"text","text":"one"}],"toolCallId":"call-1","toolName":"read","isError":false},
          {"id":"assistant-2","parentId":"result-1","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-part-2","type":"toolCall","toolCallId":"call-2","name":"bash","arguments":{"command":"pwd"},"toolSegmentId":"tool-segment:turn"}]},
          {"id":"result-2","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"result-text-2","type":"text","text":"/workspace"}],"toolCallId":"call-2","toolName":"bash","isError":false}
        ]
        """)
        let after = ChatTranscriptPresentation.timeline(in: prepended)
        #expect(after.ids == ["tool-run-call-1"])
        #expect(after.renderedIDBySemanticID["call-1"] == "tool-run-call-1")
        #expect(after.renderedIDBySemanticID["call-2"] == "tool-run-call-1")
    }

    @Test("parallel live tools keep one stable canonical row through settlement")
    func liveToolsKeepStableTimelineIdentity() throws {
        let callOne = "call-1"
        let callTwo = "call-2"
        let callThree = "call-3"
        var snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"test tools"}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Testing tools"},
          {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}},
          {"id":"part-2","type":"toolCall","toolCallId":"\(callTwo)","name":"read","arguments":{"path":"README.md"}},
          {"id":"part-3","type":"toolCall","toolCallId":"\(callThree)","name":"subagent","arguments":{}}
        ]}
        """)
        snapshot.toolExecutions = [
            tool(callOne, "bash", startedAt: "2026-01-01T00:00:01Z", toolSegmentId: "tool-segment:turn"),
            tool(callTwo, "read", startedAt: "2026-01-01T00:00:01Z", toolSegmentId: "tool-segment:turn"),
            tool(callThree, "subagent", startedAt: "2026-01-01T00:00:01Z", toolSegmentId: "tool-segment:turn"),
        ]

        let live = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(live.ids == ["user", "streaming", "tool-run-call-1"])
        guard case .toolRun(let liveRun) = live.items.last else {
            Issue.record("Expected a live tool run")
            return
        }
        #expect(liveRun.tools.map(\.id) == [callOne, callTwo, callThree])
        #expect(liveRun.title == "Using 3 tools")

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Testing tools"},
          {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}}
        ]}
        """)
        snapshot.toolExecutions = [snapshot.toolExecutions[0]]
        let partial = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(partial.ids.last == "tool-run-call-1")

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Testing tools"},
          {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}},
          {"id":"part-2","type":"toolCall","toolCallId":"\(callTwo)","name":"read","arguments":{"path":"README.md"}},
          {"id":"part-3","type":"toolCall","toolCallId":"\(callThree)","name":"subagent","arguments":{}}
        ]}
        """)
        snapshot.toolExecutions = [
            tool(callThree, "subagent", startedAt: "2026-01-01T00:00:01Z", order: 2),
            tool(callOne, "bash", startedAt: "2026-01-01T00:00:01Z", order: 0),
            tool(callTwo, "read", startedAt: "2026-01-01T00:00:01Z", order: 1),
        ]
        let expanded = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(expanded.ids.last == partial.ids.last)
        guard case .toolRun(let expandedRun) = expanded.items.last else {
            Issue.record("Expected expanded live tool run")
            return
        }
        #expect(expandedRun.tools.map(\.id) == [callOne, callTwo, callThree])

        snapshot.transcript = try transcript("""
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"test tools"}]},
          {"id":"assistant-tools","parentId":"user","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
            {"id":"thinking","type":"thinking","text":"Testing tools"},
            {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}},
            {"id":"part-2","type":"toolCall","toolCallId":"\(callTwo)","name":"read","arguments":{"path":"README.md"}},
            {"id":"part-3","type":"toolCall","toolCallId":"\(callThree)","name":"subagent","arguments":{}}
          ]},
          {"id":"result-1","parentId":"assistant-tools","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"r1","type":"text","text":"one"}],"toolCallId":"\(callOne)","toolName":"bash","isError":false},
          {"id":"result-2","parentId":"result-1","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"r2","type":"text","text":"two"}],"toolCallId":"\(callTwo)","toolName":"read","isError":false},
          {"id":"result-3","parentId":"result-2","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"r3","type":"text","text":"three"}],"toolCallId":"\(callThree)","toolName":"subagent","isError":false}
        ]
        """)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"All done"}]}
        """)
        snapshot.toolExecutions = snapshot.toolExecutions.map {
            tool($0.toolCallId, $0.toolName, status: .completed, startedAt: $0.startedAt)
        }

        let completing = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(completing.ids == ["user", "assistant-tools", "tool-run-call-1", "streaming"])
        #expect(completing.ids.filter { $0 == "tool-run-call-1" }.count == 1)
        guard case .toolRun(let completedRun) = completing.items[2] else {
            Issue.record("Expected the settled tool run before the response")
            return
        }
        #expect(completedRun.title == "Used 3 tools")

        snapshot.transcript.append(try message("""
        {"id":"assistant-final","parentId":"result-3","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"All done"}]}
        """))
        snapshot.streaming = nil
        snapshot.toolExecutions = []
        let settled = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(settled.ids == ["user", "assistant-tools", "tool-run-call-1", "assistant-final"])
    }

    @Test("streaming and canonical assistant rows share projected identity")
    func streamingSettlementKeepsVisualIdentity() throws {
        var liveSnapshot = try fixture(transcript: "[]")
        liveSnapshot.phase = .running
        liveSnapshot.streaming = try message("""
        {"id":"stream-live","parentId":"user","presentationId":"stream:turn","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"answer","ordinal":0,"type":"text","text":"hello"}]}
        """)
        var settledSnapshot = liveSnapshot
        settledSnapshot.phase = .idle
        settledSnapshot.revision += 1
        settledSnapshot.eventSequence += 1
        settledSnapshot.transcript = [try message("""
        {"id":"assistant-final","parentId":"user","presentationId":"stream:turn","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"answer","ordinal":0,"type":"text","text":"hello"}]}
        """)]
        settledSnapshot.streaming = nil
        let live = ChatTranscriptPresentation.timeline(in: liveSnapshot)
        let settled = ChatTranscriptPresentation.timeline(in: settledSnapshot)
        #expect(live.ids == ["stream:turn"])
        #expect(settled.ids == ["stream:turn"])
    }

    @Test("thinking-only settlement preserves row and run identity after leading trimming")
    func thinkingSettlementKeepsVisualIdentity() throws {
        var liveSnapshot = try fixture(transcript: "[]")
        liveSnapshot.phase = .running
        liveSnapshot.streaming = try message("""
        {"id":"stream-live","parentId":"user","presentationId":"stream:thinking","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"stream:thinking:0","ordinal":0,"thinkingRunOrdinal":0,"type":"thinking","text":"first"},
          {"id":"stream:thinking:1","ordinal":1,"thinkingRunOrdinal":0,"type":"thinking","text":"second"}
        ]}
        """)
        var settledSnapshot = liveSnapshot
        settledSnapshot.phase = .idle
        settledSnapshot.transcript = [try message("""
        {"id":"assistant-final","parentId":"user","presentationId":"stream:thinking","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"stream:thinking:1","ordinal":1,"thinkingRunOrdinal":0,"type":"thinking","text":"second"}
        ]}
        """)]
        settledSnapshot.streaming = nil

        let live = ChatTranscriptPresentation.timeline(in: liveSnapshot)
        let settled = ChatTranscriptPresentation.timeline(in: settledSnapshot)
        #expect(live.ids == settled.ids)
        guard case .message(let liveMessage) = live.items.first,
              case .message(let settledMessage) = settled.items.first,
              case .thinking(let liveRun) = liveMessage.parts.first,
              case .thinking(let settledRun) = settledMessage.parts.first else {
            Issue.record("Expected thinking presentations")
            return
        }
        #expect(liveRun.id == "thinking-run-0")
        #expect(settledRun.id == liveRun.id)
    }

    @Test("isolated text streaming tail is identical when no runtime tool is unanchored")
    func isolatedStreamingParity() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"prompt","type":"text","text":"continue"}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = []
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":"user","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"thinking","type":"thinking","text":"Preparing"},{"id":"answer","type":"text","text":"Current answer"}]}
        """)

        let cold = ChatTranscriptPresentation.timeline(in: snapshot)
        let streaming = try #require(snapshot.streaming)
        var baseSnapshot = snapshot
        baseSnapshot.streaming = nil
        let base = ChatTranscriptPresentation.timeline(in: baseSnapshot)
        let live = try #require(ChatTranscriptProjectionKernel.isolatedStreamingTimeline(streaming))
        let incremental = base.appendingLive(live)

        #expect(incremental == cold)
        #expect(incremental.items.canonical.count == base.items.count)
        #expect(incremental.items.live.count == 1)
    }

    @Test("one canonical collision keeps unrelated live rows and semantic indexes")
    func liveCollisionFiltersOnlyTheDuplicate() throws {
        let canonical = ChatTranscriptRenderItem.transcript(try message("""
        {"id":"collision","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"canonical","type":"text","text":"settled"}]}
        """))
        let duplicate = ChatTranscriptRenderItem.transcript(try message("""
        {"id":"collision","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"duplicate","type":"text","text":"live duplicate"}]}
        """))
        let survivor = ChatTranscriptRenderItem.transcript(try message("""
        {"id":"survivor","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"survivor-text","type":"text","text":"still live"}]}
        """))
        let base = ChatTranscriptTimeline(
            items: ChatTranscriptItems(canonical: [canonical]),
            preferredSemanticIDByRenderedID: ChatSemanticIndex(
                canonical: ["collision": "semantic-collision"]
            ),
            renderedIDBySemanticID: ChatSemanticIndex(
                canonical: ["semantic-collision": "collision"]
            )
        )
        let live = ChatTranscriptTimeline(
            items: ChatTranscriptItems(canonical: [], live: [duplicate, survivor]),
            preferredSemanticIDByRenderedID: ChatSemanticIndex(
                canonical: [:],
                live: [
                    "collision": "semantic-collision",
                    "survivor": "semantic-survivor",
                ]
            ),
            renderedIDBySemanticID: ChatSemanticIndex(
                canonical: [:],
                live: [
                    "semantic-collision": "collision",
                    "semantic-survivor": "survivor",
                ]
            )
        )

        let result = base.appendingLive(live)

        #expect(result.items.live.map { $0.id } == ["survivor"])
        #expect(result.preferredSemanticIDByRenderedID["survivor"] == "semantic-survivor")
        #expect(result.renderedIDBySemanticID["semantic-survivor"] == "survivor")
        #expect(result.isInternallyConsistent)
    }

    @Test("explicit empty tool output never falls back to duplicated request content")
    func explicitEmptyToolOutputPreservesDetailParity() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"call","ordinal":0,"type":"toolCall","toolCallId":"empty-output","name":"read","arguments":{}}
          ]}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = [
            tool(
                "empty-output",
                "read",
                status: .completed,
                startedAt: "2026-01-01T00:00:01Z",
                output: ""
            ),
        ]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let run) = candidate.timeline.items.first,
              let descriptor = run.tools.first,
              let tool = candidate.toolPayloads.resolving(descriptor) else {
            Issue.record("Expected completed tool row")
            return
        }
        #expect(tool.content == "")
        #expect(tool.fallbackContent == nil)
        #expect(tool.response == .object(["ok": .bool(true)]))
    }

    @Test("live tool order is deterministic when progress events arrive out of order")
    func deterministicLiveToolOrder() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [
            tool("later", "read", startedAt: "2026-01-01T00:00:01Z", order: 2, toolSegmentId: "tool-segment:turn"),
            tool("same-b", "bash", startedAt: "2026-01-01T00:00:01Z", order: 1, toolSegmentId: "tool-segment:turn"),
            tool("same-a", "find", startedAt: "2026-01-01T00:00:01Z", order: 0, toolSegmentId: "tool-segment:turn"),
        ]
        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)
        let runs = timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.map { $0.tools.map(\.id) } == [["same-a", "same-b", "later"]])
        #expect(timeline.renderedIDBySemanticID["same-a"] == "tool-run-same-a")
        #expect(timeline.renderedIDBySemanticID["same-b"] == "tool-run-same-a")
        #expect(timeline.renderedIDBySemanticID["later"] == "tool-run-same-a")
    }

    @Test("live output, monotonic progress, and execution timing stay auditable")
    func liveToolAuditProjection() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"wait","name":"subagent_wait","arguments":{"id":"child"}}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = [ToolExecutionState(
            toolCallId: "wait",
            toolName: "subagent_wait",
            order: 0,
            status: .running,
            arguments: .object(["id": .string("child")]),
            partialResult: .object(["content": .array([.object(["type": .string("text"), "text": .string("Waiting 12s · reviewer: read")])])]),
            result: nil,
            output: "Waiting 12s · reviewer: read",
            outputTruncated: true,
            isError: false,
            startedAt: "2026-01-01T00:00:01Z",
            updatedAt: "2026-01-01T00:00:13Z",
            lastProgressAt: "2026-01-01T00:00:13Z",
            progressSequence: 14
        )]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected live tool run")
            return
        }
        let descriptor = try #require(run.tools.first)
        let tool = try #require(candidate.toolPayloads.resolving(descriptor))
        #expect(tool.content == "Waiting 12s · reviewer: read")
        #expect(tool.outputTruncated)
        #expect(tool.progressSequence == 14)
        #expect(tool.elapsedMilliseconds(at: try #require(ToolTiming.date("2026-01-01T00:00:13Z"))) == 12_000)
        #expect(ToolTiming.format(milliseconds: 0) == "0ms")
        #expect(ToolTiming.format(milliseconds: 99) == "99ms")
        #expect(ToolTiming.format(milliseconds: 100) == "100ms")
        #expect(ToolTiming.format(milliseconds: 999) == "999ms")
        #expect(ToolTiming.format(milliseconds: 1_000) == "1.0s")
        #expect(ToolTiming.format(milliseconds: 478_000) == "7m 58s")
    }

    @Test("tool timing parses cached ISO timestamps with and without fractional seconds")
    func toolTimingISOParsing() throws {
        let whole = try #require(ToolTiming.date("2026-01-01T00:00:01Z"))
        let fractional = try #require(ToolTiming.date("2026-01-01T00:00:01.125Z"))
        #expect(Int((fractional.timeIntervalSince(whole) * 1_000).rounded()) == 125)
        #expect(ToolTiming.intervalMilliseconds(
            start: "2026-01-01T00:00:01.125Z",
            end: "2026-01-01T00:00:02Z"
        ) == 875)
        #expect(ToolTiming.date("not-a-timestamp") == nil)
    }

    @Test("canonical history derives timing when exact runtime metadata is unavailable")
    func canonicalTimingFallback() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"read","name":"read","arguments":{}}]},
          {"id":"result","parentId":"assistant","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"text","type":"text","text":"done"}],"toolCallId":"read","toolName":"read","isError":false,"completedAt":"2026-01-01T00:00:03Z"}
        ]
        """)
        guard case .toolRun(let run) = ChatTranscriptPresentation.timeline(in: snapshot).items.first,
              let tool = run.tools.first else {
            Issue.record("Expected canonical tool run")
            return
        }
        #expect(tool.durationMs == 2_000)
        #expect(tool.elapsedMilliseconds() == 2_000)
    }

    @Test("Gateway duration is authoritative and tool runs accumulate durations")
    func completedAndAccumulatedTiming() {
        let first = ChatToolPresentation(
            id: "first", title: "edit", subtitle: "Completed", request: nil, response: nil,
            content: "", fallbackContent: nil, error: false,
            startedAt: "2026-01-01T00:00:01Z", completedAt: "2026-01-01T00:00:03Z",
            durationMs: 25, lastProgressAt: nil, progressSequence: nil
        )
        let second = ChatToolPresentation(
            id: "second", title: "write", subtitle: "Completed", request: nil, response: nil,
            content: "", fallbackContent: nil, error: false,
            startedAt: "2026-01-01T00:00:04Z", completedAt: "2026-01-01T00:00:07Z",
            durationMs: 40, lastProgressAt: nil, progressSequence: nil
        )
        let run = ChatToolRunPresentation(tools: [first.descriptor, second.descriptor])

        #expect(first.elapsedMilliseconds() == 25)
        #expect(second.elapsedMilliseconds() == 40)
        #expect(run.elapsedMilliseconds() == 65)
    }

    @Test("running Gateway duration does not use the device wall clock")
    func runningGatewayDurationIsAuthoritative() throws {
        let tool = ChatToolPresentation(
            id: "running", title: "bash", subtitle: "Running", request: nil, response: nil,
            content: "", fallbackContent: nil, error: false,
            startedAt: "2026-01-01T00:00:01Z", completedAt: nil,
            durationMs: 237, lastProgressAt: "2026-01-01T00:00:02Z", progressSequence: 2
        )

        let farFuture = try #require(ToolTiming.date("2036-01-01T00:00:01Z"))
        #expect(tool.elapsedMilliseconds(at: farFuture) == 237)
    }

    @Test("conversation content interrupts tool grouping")
    func conversationBreaksToolRuns() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant-tool","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part","type":"toolCall","toolCallId":"call","name":"read","arguments":{}}]},
          {"id":"result","parentId":"assistant-tool","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"done"}],"toolCallId":"call","toolName":"read","isError":false},
          {"id":"assistant-text","parentId":"result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"Finished"}]},
          {"id":"bash","parentId":"assistant-text","timestamp":"2026-01-01T00:00:03Z","kind":"bash","command":"pwd","output":"/workspace","exitCode":0,"cancelled":false,"truncated":false}
        ]
        """)

        let rendered = ChatTranscriptPresentation.timeline(in: snapshot).items
        #expect(rendered.count == 3)
        #expect(rendered.map(\.id) == ["tool-run-call", "assistant-text", "bash"])
    }

    @Test("idle snapshots never present retained foreground tools as running")
    func idleRunningToolIsInterrupted() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"wait","name":"subagent_wait","label":"Subagent Wait","arguments":{}}]}
        ]
        """)
        snapshot.toolExecutions = [tool("wait", "subagent_wait", startedAt: "2026-01-01T00:00:01Z")]

        guard case .toolRun(let run) = ChatTranscriptPresentation.timeline(in: snapshot).items.first else {
            Issue.record("Expected retained tool run")
            return
        }
        #expect(run.title == "Subagent Wait")
        #expect(!run.isRunning)
        #expect(run.tools.first?.subtitle == "Interrupted")
    }

    @Test("canonical submission handoffs are page bounded")
    func canonicalSubmissionHandoffBound() {
        var ledger = BoundedChatIdentityLedger()
        let capacity = ChatTranscriptPageRequest.maximumItemCount
        ledger.formUnion(Set((0..<(capacity + 4)).map { "submission-\($0)" }))
        #expect(ledger.ids.count == capacity)
        #expect(!ledger.contains("submission-0"))
        #expect(ledger.contains("submission-\(capacity + 3)"))
    }

    @Test("legacy pending suppression uses exact newest canonical evidence")
    func legacyPendingCanonicalSuppression() throws {
        let pending = SessionSnapshot.PendingPrompt(
            id: "pending", createdAt: nil, behavior: .steer,
            text: "repeat", attachmentCount: 0, photoCount: 0, fileAttachmentCount: 0
        )
        let matching = try fixture(transcript: """
        [{"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"repeat"}]}]
        """)
        #expect(ChatPendingCanonicalSuppressionPolicy.suppresses(pending, in: matching.transcript))

        let malformed = SessionSnapshot.PendingPrompt(
            id: "pending", createdAt: "not-a-timestamp", behavior: .steer,
            text: "repeat", attachmentCount: 0, photoCount: 0, fileAttachmentCount: 0
        )
        #expect(ChatPendingCanonicalSuppressionPolicy.suppresses(malformed, in: matching.transcript))

        let repeatedOlder = try fixture(transcript: """
        [
          {"id":"old","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"repeat"}]},
          {"id":"new","parentId":"old","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"different"}]}
        ]
        """)
        #expect(!ChatPendingCanonicalSuppressionPolicy.suppresses(pending, in: repeatedOlder.transcript))
    }

    @Test("pending suppression requires exact attachment evidence")
    func pendingCanonicalAttachmentEvidence() throws {
        let pending = SessionSnapshot.PendingPrompt(
            id: "pending", createdAt: nil, behavior: nil,
            text: "photo", attachmentCount: 1, photoCount: 1, fileAttachmentCount: 0
        )
        let mismatch = try fixture(transcript: """
        [{"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"photo"}]}]
        """)
        #expect(!ChatPendingCanonicalSuppressionPolicy.suppresses(pending, in: mismatch.transcript))

        let match = try fixture(transcript: """
        [{"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"photo"},{"id":"image","type":"image","mimeType":"image/png"}]}]
        """)
        #expect(ChatPendingCanonicalSuppressionPolicy.suppresses(pending, in: match.transcript))
    }

    @Test("timestamped pending suppression preserves canonical ordering")
    func timestampedPendingCanonicalOrdering() throws {
        let pending = SessionSnapshot.PendingPrompt(
            id: "pending", createdAt: "2026-01-01T00:00:02Z", behavior: nil,
            text: "same", attachmentCount: 0, photoCount: nil, fileAttachmentCount: nil
        )
        let olderOnly = try fixture(transcript: """
        [{"id":"older","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"same"}]}]
        """)
        #expect(!ChatPendingCanonicalSuppressionPolicy.suppresses(pending, in: olderOnly.transcript))
        let ordered = try fixture(transcript: """
        [
          {"id":"older","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"same"}]},
          {"id":"newer","parentId":"older","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"same"}]}
        ]
        """)
        #expect(ChatPendingCanonicalSuppressionPolicy.suppresses(pending, in: ordered.transcript))
    }

    @Test("entrance geometry follows exact displayed install across desired and identity replacements")
    func entranceGeometryAdmissionPolicy() throws {
        var displayed = try fixture(transcript: "[]")
        let displayedTag = ChatTranscriptProjectionTag(
            snapshot: displayed,
            presentationGeneration: 41,
            canonicalGeneration: 10,
            timelineGeneration: 20
        )
        var desired = displayed
        desired.eventSequence += 1
        let desiredTag = ChatTranscriptProjectionTag(
            snapshot: desired,
            presentationGeneration: 41,
            canonicalGeneration: 10,
            timelineGeneration: 21
        )
        let observation = ChatSemanticFrameObservation(
            layoutEpoch: 7,
            frame: CGRect(x: 0, y: 10, width: 100, height: 30),
            entranceAdmissionTag: displayedTag
        )

        // Model-ahead desired source is intentionally absent from the policy:
        // the displayed A installation remains sufficient admission authority.
        #expect(desiredTag != displayedTag)
        #expect(ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: displayedTag,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .pending
        ))
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: desiredTag,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .pending
        ))

        displayed.runtimeGeneration = "replacement-runtime"
        let runtimeReplacement = ChatTranscriptProjectionTag(
            snapshot: displayed,
            presentationGeneration: 41,
            canonicalGeneration: 10,
            timelineGeneration: 20
        )
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: runtimeReplacement,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .pending
        ))
        let presentationReplacement = ChatTranscriptProjectionTag(
            snapshot: desired,
            presentationGeneration: 42,
            canonicalGeneration: 10,
            timelineGeneration: 21
        )
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: presentationReplacement,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .pending
        ))
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: displayedTag,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 8,
            entranceState: .pending
        ))
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: displayedTag,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .admitted
        ))
    }

    @Test("timeline projection closes one aggregate-only performance interval")
    func projectionSignpost() throws {
        let snapshot = try fixture(transcript: """
        [{"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"Hello"}]}]
        """)
        let signposts = RecordingPerformanceSignposts()

        let timeline = ChatTranscriptPresentation.timeline(
            in: snapshot,
            performanceSignposts: signposts
        )

        #expect(timeline.items.count == 1)
        #expect(signposts.events() == [
            .begin(.chatProjection),
            .end(.chatProjection, .success, PerformanceMetrics(itemCount: 1)),
        ])
    }

    private func toolPresentation(_ id: String, startedAt: String? = nil) -> ChatToolPresentation {
        ChatToolPresentation(
            id: id,
            title: "read",
            subtitle: "Running",
            request: nil,
            response: nil,
            content: "",
            fallbackContent: nil,
            error: false,
            startedAt: startedAt,
            completedAt: nil,
            durationMs: nil,
            lastProgressAt: nil,
            progressSequence: nil
        )
    }

    private func message(_ value: String) throws -> TranscriptItem {
        try decodeTranscriptFixture(TranscriptItem.self, from: Data(value.utf8))
    }

    private func transcript(_ value: String) throws -> [TranscriptItem] {
        try decodeTranscriptFixture([TranscriptItem].self, from: Data(value.utf8))
    }

    private func tool(
        _ id: String,
        _ name: String,
        status: ToolExecutionState.Status = .running,
        startedAt: String,
        order: Int? = nil,
        output: String? = nil,
        toolSegmentId: String? = nil,
        groupId: String? = nil,
        groupIndex: Int? = nil,
        groupCount: Int? = nil
    ) -> ToolExecutionState {
        ToolExecutionState(
            toolCallId: id,
            toolName: name,
            order: order,
            status: status,
            arguments: .object([:]),
            partialResult: nil,
            result: status == .running ? nil : .object(["ok": .bool(true)]),
            output: output,
            isError: status == .failed,
            startedAt: startedAt,
            updatedAt: startedAt,
            lastProgressAt: startedAt,
            completedAt: status == .running ? nil : startedAt,
            durationMs: status == .running ? nil : 0,
            progressSequence: 1,
            toolSegmentId: toolSegmentId,
            groupId: groupId,
            groupIndex: groupIndex,
            groupCount: groupCount,
            groupFinalized: groupId == nil ? nil : true
        )
    }

    private func fixture(transcript: String) throws -> SessionSnapshot {
        try decodeTranscriptFixture(SessionSnapshot.self, from: Data("""
        {
          "sessionId":"session","runtimeGeneration":"generation","revision":1,"eventSequence":1,"phase":"idle","cwd":"/workspace",
          "model":{"provider":"openai-codex","id":"gpt-5.6-sol"},"thinkingLevel":"high","availableThinkingLevels":["off","high"],
          "stats":{"userMessages":1,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":1,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0},
          "queueRevision":0,"queuedItems":[],"automaticCompactionEnabled":true,"transcript":\(transcript),"transcriptStart":0,"transcriptTotal":3,
          "toolExecutions":[],"extensionPresentation":{"version":3,"hostEpoch":"host","revision":0,"capabilities":[],"diagnostics":[],"semanticState":{"statuses":{},"working":{"visible":false},"widgets":[],"toolsExpanded":false,"editorRevision":0,"editorText":""},"surfaces":[],"pendingInteractions":[]},"diagnostics":[]
        }
        """.utf8))
    }
}
