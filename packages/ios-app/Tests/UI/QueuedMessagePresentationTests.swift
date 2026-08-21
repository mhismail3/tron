import Testing
@testable import TronMobile

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

    @Test("queued attachments become one inert mini chip per typed item")
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

    @Test("queued card geometry keeps compact balanced header spacing")
    func compactCardGeometry() {
        #expect(QueuedMessageCardLayout.contentSpacing == 6)
        #expect(QueuedMessageCardLayout.arrowContainerSize == 24)
        #expect(QueuedMessageCardLayout.attachmentChipSize == 22)
        #expect(QueuedMessageCardLayout.attachmentChipCornerRadius == 6)
    }
}
