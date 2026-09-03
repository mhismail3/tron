import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Queued message presentation policy")
struct QueuedMessagePresentationTests {
    @Test("queue editing requires authoritative rich state")
    func managementAvailability() {
        #expect(QueuedMessageManagementPolicy.availability(
            queueManagementCapability: true,
            queueRevision: 4,
            hasAuthoritativeItems: true
        ) == .available)
        #expect(QueuedMessageManagementPolicy.availability(
            queueManagementCapability: true,
            queueRevision: nil,
            hasAuthoritativeItems: true
        ) == .invalidProjection)
        #expect(QueuedMessageManagementPolicy.availability(
            queueManagementCapability: true,
            queueRevision: 4,
            hasAuthoritativeItems: false
        ) == .invalidProjection)
        #expect(QueuedMessageManagementPolicy.availability(
            queueManagementCapability: false,
            queueRevision: nil,
            hasAuthoritativeItems: false
        ) == .requiresGatewayUpdate)
    }

    @Test("installed authoritative queue remains manageable while transcript work advances")
    func transcriptProjectionDoesNotOwnQueueAvailability() {
        let installedAvailability = QueuedMessageManagementPolicy.availability(
            queueManagementCapability: true,
            queueRevision: 9,
            hasAuthoritativeItems: true
        )
        // Availability is intentionally a fact of the installed queue commit;
        // unrelated desired transcript tags are not an input to this policy.
        #expect(installedAvailability == .available)
        #expect(installedAvailability.isManageable)
    }

    @Test("capability replacement changes policy only with the installed commit")
    func capabilityReplacement() {
        let supported = QueuedMessageManagementPolicy.availability(
            queueManagementCapability: true,
            queueRevision: 9,
            hasAuthoritativeItems: true
        )
        let unsupported = QueuedMessageManagementPolicy.availability(
            queueManagementCapability: false,
            queueRevision: 9,
            hasAuthoritativeItems: true
        )
        #expect(supported == .available)
        #expect(unsupported == .requiresGatewayUpdate)
    }

    @Test("only authoritative rich queue state permits mutation")
    func mutationGate() {
        #expect(QueuedMessageManagementAvailability.available.isManageable)
        #expect(!QueuedMessageManagementAvailability.requiresGatewayUpdate.isManageable)
        #expect(!QueuedMessageManagementAvailability.invalidProjection.isManageable)
    }

    @Test("queue lineage changes only for edited or removed operations")
    func changedQueueOperationIDs() {
        let first = SessionSnapshot.QueuedMessage(
            id: "first", behavior: .steer, text: "one", attachmentCount: 0
        )
        let second = SessionSnapshot.QueuedMessage(
            id: "second", behavior: .followUp, text: "two", attachmentCount: 0
        )
        #expect(QueuedMessageManagementPolicy.changedOperationIDs(
            from: [first, second],
            to: [second, first]
        ).isEmpty)

        var edited = first
        edited.text = "edited"
        #expect(QueuedMessageManagementPolicy.changedOperationIDs(
            from: [first, second],
            to: [edited]
        ) == ["first", "second"])
        #expect(QueuedMessageManagementPolicy.changedOperationIDs(
            from: [first, second],
            to: []
        ) == ["first", "second"])
    }

    @Test("exact descriptors survive compact chip projection while legacy files fail closed")
    func attachmentDescriptors() throws {
        let attachment = SessionSnapshot.PromptAttachment(
            id: "upload", name: "notes.txt", mimeType: "text/plain", size: 4
        )
        let exact = SessionSnapshot.QueuedMessage(
            id: "exact",
            behavior: .steer,
            text: "review",
            attachmentCount: 1,
            photoCount: 0,
            fileAttachmentCount: 1,
            attachments: [attachment]
        )
        let exactChip = try #require(QueuedMessageAttachmentPresentation.chips(for: exact).first)
        #expect(exactChip.kind == .file)
        #expect(exactChip.attachment == attachment)

        let legacy = QueuedMessageAttachmentPresentation.chips(
            attachmentCount: 1,
            photoCount: 0,
            fileAttachmentCount: 1
        )
        #expect(legacy.count == 1)
        #expect(legacy[0].kind == .file)
        #expect(legacy[0].attachment == nil)
    }

    @Test("queued attachment descriptors decode additively")
    func attachmentDescriptorDecoding() throws {
        let data = Data(#"{"id":"queued","behavior":"steer","text":"review","attachmentCount":1,"photoCount":0,"fileAttachmentCount":1,"attachments":[{"id":"upload","name":"notes.txt","mimeType":"text/plain","size":4}]}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionSnapshot.QueuedMessage.self, from: data)
        #expect(decoded.attachments == [
            .init(id: "upload", name: "notes.txt", mimeType: "text/plain", size: 4),
        ])

        let legacy = Data(#"{"id":"legacy","behavior":"followUp","text":"later","attachmentCount":1}"#.utf8)
        #expect(try JSONDecoder().decode(SessionSnapshot.QueuedMessage.self, from: legacy).attachments == nil)
    }

    @Test("canonical boundary waits for queue mutation outcome before choosing identity")
    func canonicalBoundaryOrdersAfterQueueMutationOutcome() {
        let affected: Set<String> = ["operation"]

        // The same canonical capture is ambiguous while replaceQueue is
        // suspended: without local exclusions it settles the consumed queue
        // row, while successful removal makes that identity unrelated.
        #expect(ChatQueueMutationProjectionPolicy.shouldDefer(
            affectedOperationIDs: affected,
            receiptOperationID: "operation",
            fallbackHandoffWithoutExclusions: "canonical",
            fallbackHandoffWithExclusions: nil
        ))

        // Failure installs the held capture under original queue semantics, so
        // the exact canonical row consumes no second entrance.
        #expect(ChatQueueMutationProjectionPolicy.exclusions(
            for: .failure,
            affectedOperationIDs: affected
        ).isEmpty)

        // Success installs the same held capture only after retiring exact
        // lineage; the unrelated canonical identity remains unsuppressed.
        #expect(ChatQueueMutationProjectionPolicy.exclusions(
            for: .success,
            affectedOperationIDs: affected
        ) == affected)
    }

    @Test("ordinary transcript intake does not wait for unrelated queue mutations")
    func ordinaryTranscriptIntakeDoesNotDefer() {
        #expect(!ChatQueueMutationProjectionPolicy.shouldDefer(
            affectedOperationIDs: ["edited"],
            receiptOperationID: "other",
            fallbackHandoffWithoutExclusions: "canonical",
            fallbackHandoffWithExclusions: "canonical"
        ))
    }

    @Test("newer queue revisions retire controls only after command outcome")
    func newerQueueRevisionOrdering() {
        // Snapshot-before-response, including an external conflicting revision,
        // preserves UI ownership and lineage while the command is unresolved.
        #expect(!ChatQueueMutationProjectionPolicy.shouldRetirePresentationState(
            commandIsPending: true,
            expectedRevision: 10,
            installedRevision: 12
        ))
        // Once success is known, that already-installed authority clears now.
        #expect(ChatQueueMutationProjectionPolicy.shouldRetirePresentationState(
            commandIsPending: false,
            expectedRevision: 10,
            installedRevision: 12
        ))
        // Response-before-snapshot keeps ownership until a newer frame arrives.
        #expect(!ChatQueueMutationProjectionPolicy.shouldRetirePresentationState(
            commandIsPending: false,
            expectedRevision: 10,
            installedRevision: 10
        ))
        #expect(ChatQueueMutationProjectionPolicy.shouldRetirePresentationState(
            commandIsPending: false,
            expectedRevision: 10,
            installedRevision: 11
        ))
        // Conflict/failure restores the original interpretation directly.
        #expect(ChatQueueMutationProjectionPolicy.exclusions(
            for: .failure,
            affectedOperationIDs: ["operation"]
        ).isEmpty)
    }

    @Test("queue mutation resolution suspends every waiter and wakes without polling")
    func queueMutationResolutionWaiters() async throws {
        let owner = ChatQueueMutationResolutionOwner()
        let token = try #require(owner.begin())
        let first = Task { @MainActor in try await owner.wait(for: token) }
        let second = Task { @MainActor in try await owner.wait(for: token) }
        await Task.yield()
        #expect(owner.waiterCount == 2)
        #expect(owner.resolve(token, as: .commandCompleted))
        #expect(try await first.value == .commandCompleted)
        #expect(try await second.value == .commandCompleted)
        #expect(owner.waiterCount == 0)
        #expect(owner.activeToken == nil)
    }

    @Test("queue mutation retirement cancels lifecycle wait and rejects stale completion")
    func queueMutationRetirementAndStaleCompletion() async throws {
        let owner = ChatQueueMutationResolutionOwner()
        let staleToken = try #require(owner.begin())
        let waiter = Task { @MainActor in try await owner.wait(for: staleToken) }
        await Task.yield()
        #expect(owner.waiterCount == 1)

        // Models disappearance/open retirement: all installers wake as retired.
        owner.retire()
        #expect(try await waiter.value == .retired)
        #expect(owner.waiterCount == 0)

        let currentToken = try #require(owner.begin())
        #expect(!owner.resolve(staleToken, as: .commandCompleted))
        #expect(owner.isActive(currentToken))
        #expect(owner.resolve(currentToken, as: .retired))
    }

    @Test("cancelled queue mutation waiter is removed without retiring its peers")
    func queueMutationWaiterCancellation() async throws {
        let owner = ChatQueueMutationResolutionOwner()
        let token = try #require(owner.begin())
        let cancelled = Task { @MainActor in try await owner.wait(for: token) }
        let surviving = Task { @MainActor in try await owner.wait(for: token) }
        await Task.yield()
        #expect(owner.waiterCount == 2)

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("cancelled waiter unexpectedly completed")
        } catch is CancellationError {
            // Expected cancellation is caller-local.
        }
        #expect(owner.waiterCount == 1)
        #expect(owner.resolve(token, as: .commandCompleted))
        #expect(try await surviving.value == .commandCompleted)
    }

    @Test("exact token settlement and stale completion immunity")
    func exactTokenSettlement() {
        var owner = ChatEarlierMessagesOperationOwner()
        let first = owner.begin()
        #expect(first != nil)
        owner.settle(first! &+ 1)
        #expect(owner.isActive)

        owner.settle(first!)
        let second = owner.begin()
        #expect(second != nil)
        owner.settle(first!)
        #expect(owner.activeToken == second)
        owner.settle(second!)
        #expect(!owner.isActive)
    }

    @Test("ordinary projection updates remain available")
    func ordinaryProjectionDoesNotLoadPill() {
        let owner = ChatEarlierMessagesOperationOwner()
        #expect(ChatEarlierMessagesOperationPolicy.phase(
            owner: owner,
            modelLoading: false,
            scrollLoading: false
        ) == .available)
    }

    @Test("request and scroll loading evidence stay in loading phase")
    func supportingLoadingEvidence() {
        let owner = ChatEarlierMessagesOperationOwner()
        #expect(ChatEarlierMessagesOperationPolicy.phase(
            owner: owner,
            modelLoading: true,
            scrollLoading: false
        ) == .loading)
        #expect(ChatEarlierMessagesOperationPolicy.phase(
            owner: owner,
            modelLoading: false,
            scrollLoading: true
        ) == .loading)

        var admitted = owner
        let token = admitted.begin()!
        #expect(ChatEarlierMessagesOperationPolicy.phase(
            owner: admitted,
            modelLoading: false,
            scrollLoading: false
        ) == .loading)
        admitted.settle(token)
    }

    @Test("queued attachments become one compact mini chip per typed item")
    func attachmentPresentation() {
        #expect(QueuedMessageAttachmentPresentation.chips(
            attachmentCount: 3,
            photoCount: 3,
            fileAttachmentCount: 0
        ) == [
            .init(id: "photo-0", kind: .photo),
            .init(id: "photo-1", kind: .photo),
            .init(id: "photo-2", kind: .photo),
        ])
        #expect(QueuedMessageAttachmentPresentation.chips(
            attachmentCount: 2,
            photoCount: 0,
            fileAttachmentCount: 2
        ) == [
            .init(id: "file-0", kind: .file),
            .init(id: "file-1", kind: .file),
        ])
        #expect(QueuedMessageAttachmentPresentation.chips(
            attachmentCount: 1,
            photoCount: nil,
            fileAttachmentCount: nil
        ) == [
            .init(id: "file-0", kind: .file),
        ])
    }

    @Test("frozen submission attachments use typed queue chips and labels")
    func frozenAttachmentChips() {
        let chips = QueuedMessageAttachmentPresentation.chips(for: [
            PendingAttachment(id: "photo", name: "one.jpg", mimeType: "IMAGE/JPEG", size: 1, previewData: nil),
            PendingAttachment(id: "file", name: "notes.txt", mimeType: "text/plain", size: 2, previewData: nil),
        ])
        #expect(chips.map(\.kind) == [.photo, .file])
        #expect(QueuedMessageAttachmentPresentation.accessibilityLabel(chips: chips) == "1 photo, 1 file")
    }

    @Test("exact mixed attachments preserve upload identity across canonical ordering")
    func mixedAttachmentOrderingMatchesCanonicalCounts() {
        let attachments = [
            PendingAttachment(id: "file", name: "notes.txt", mimeType: "text/plain", size: 1, previewData: nil),
            PendingAttachment(id: "photo", name: "photo.jpg", mimeType: "image/jpeg", size: 1, previewData: nil),
            PendingAttachment(id: "file-2", name: "data.json", mimeType: "application/json", size: 1, previewData: nil),
        ]
        let chips = QueuedMessageAttachmentPresentation.chips(for: attachments)
        #expect(chips.map(\.id) == [
            "attachment-upload:photo",
            "attachment-upload:file",
            "attachment-upload:file-2",
        ])
        #expect(chips.map(\.kind) == [.photo, .file, .file])
        #expect(chips.compactMap(\.attachment?.id) == ["upload:photo", "upload:file", "upload:file-2"])
    }

    @Test("duplicate authoritative attachment identities fail back to typed slots")
    func duplicateAttachmentIdentitiesUsePlaceholders() {
        let duplicate = SessionSnapshot.PromptAttachment(
            id: "upload:duplicate",
            name: "same.txt",
            mimeType: "text/plain",
            size: 4
        )
        let chips = QueuedMessageAttachmentPresentation.chips(
            attachmentCount: 2,
            photoCount: 0,
            fileAttachmentCount: 2,
            attachments: [duplicate, duplicate]
        )
        #expect(chips.map(\.id) == ["file-0", "file-1"])
        #expect(chips.allSatisfy { $0.attachment == nil })
    }

    @Test("transport chips use Gateway upload identity while preserving local chip identity")
    func divergentAttachmentIdentity() throws {
        let attachment = PendingAttachment(
            id: "local-chip",
            gatewayUploadID: "gateway-upload",
            name: "notes.txt",
            mimeType: "text/plain",
            size: 4,
            previewData: nil
        )
        #expect(attachment.id == "local-chip")
        #expect(attachment.transportBlobID == "upload:gateway-upload")
        let chip = try #require(QueuedMessageAttachmentPresentation.chips(for: [attachment]).first)
        #expect(chip.id == "attachment-upload:gateway-upload")
        #expect(chip.attachment?.id == "upload:gateway-upload")
        #expect(QueuedMessageAttachmentPresentation.chips(for: [attachment.requiringUpload()]).isEmpty)
    }

    @Test("queued card geometry keeps compact balanced header spacing")
    func compactCardGeometry() {
        #expect(QueuedMessageCardLayout.contentSpacing == 6)
        #expect(QueuedMessageCardLayout.arrowContainerSize == 24)
        #expect(QueuedMessageCardLayout.attachmentChipSize == 22)
        #expect(QueuedMessageCardLayout.attachmentChipCornerRadius == 6)
    }
}
