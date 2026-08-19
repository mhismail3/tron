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

    @Test("typed photo counts use photo presentation while file counts retain attachment presentation")
    func attachmentPresentation() {
        #expect(QueuedMessageAttachmentPresentation.lines(
            attachmentCount: 3,
            photoCount: 3,
            fileAttachmentCount: 0
        ) == [
            .init(id: "photos", iconName: "photo.on.rectangle", text: "3 photos"),
        ])
        #expect(QueuedMessageAttachmentPresentation.lines(
            attachmentCount: 2,
            photoCount: 0,
            fileAttachmentCount: 2
        ) == [
            .init(id: "attachments", iconName: "paperclip", text: "2 attachments"),
        ])
        #expect(QueuedMessageAttachmentPresentation.lines(
            attachmentCount: 1,
            photoCount: nil,
            fileAttachmentCount: nil
        ) == [
            .init(id: "attachments", iconName: "paperclip", text: "1 attachment"),
        ])
    }
}
