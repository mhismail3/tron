import Testing
@testable import TronMobile

@Suite("Queued message presentation policy")
struct QueuedMessagePresentationTests {
    @Test("queue editing requires authoritative rich state")
    func managementAvailability() {
        #expect(QueuedMessageManagementPolicy.availability(
            capabilities: [QueuedMessageManagementPolicy.capability],
            queueRevision: 4,
            hasAuthoritativeItems: true
        ) == .available)
        #expect(QueuedMessageManagementPolicy.availability(
            capabilities: [QueuedMessageManagementPolicy.capability],
            queueRevision: nil,
            hasAuthoritativeItems: true
        ) == .invalidProjection)
        #expect(QueuedMessageManagementPolicy.availability(
            capabilities: [QueuedMessageManagementPolicy.capability],
            queueRevision: 4,
            hasAuthoritativeItems: false
        ) == .invalidProjection)
        #expect(QueuedMessageManagementPolicy.availability(
            capabilities: [],
            queueRevision: nil,
            hasAuthoritativeItems: false
        ) == .requiresGatewayUpdate)
    }

    @Test("only authoritative rich queue state permits mutation")
    func mutationGate() {
        #expect(QueuedMessageManagementAvailability.available.isManageable)
        #expect(!QueuedMessageManagementAvailability.requiresGatewayUpdate.isManageable)
        #expect(!QueuedMessageManagementAvailability.invalidProjection.isManageable)
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
