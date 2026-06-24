import XCTest
@testable import TronMobile

@MainActor
final class MessagingCoordinatorDraftTests: XCTestCase {
    var coordinator: MessagingCoordinator!
    var mockContext: MockMessagingContext!

    override func setUp() async throws {
        mockContext = MockMessagingContext()
        coordinator = MessagingCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    func testSendMessageClearsDraftAfterSend() async {
        let db = EventDatabase()!
        try! await db.initialize()
        try! await db.clearAll()
        let store = DraftStore(eventDatabase: db, documentsURL: FileManager.default.temporaryDirectory)
        mockContext.draftStore = store

        let draftState = InputBarState()
        draftState.text = "draft text"
        await store.saveImmediately(sessionId: "test-session", inputBarState: draftState)

        let checkState = InputBarState()
        let hasDraft = await store.loadDraft(sessionId: "test-session", into: checkState)
        XCTAssertTrue(hasDraft)

        mockContext.inputText = "Test message"
        await coordinator.sendMessage(context: mockContext)

        let afterState = InputBarState()
        let hasDraftAfter = await store.loadDraft(sessionId: "test-session", into: afterState)
        XCTAssertFalse(hasDraftAfter)

        store.removeAllDraftFiles()
        try? await db.clearAll()
        await db.close()
    }

    func testSendMessageClearsDraftEvenOnServerError() async {
        let db = EventDatabase()!
        try! await db.initialize()
        try! await db.clearAll()
        let store = DraftStore(eventDatabase: db, documentsURL: FileManager.default.temporaryDirectory)
        mockContext.draftStore = store

        let draftState = InputBarState()
        draftState.text = "draft"
        await store.saveImmediately(sessionId: "test-session", inputBarState: draftState)

        mockContext.inputText = "Test"
        mockContext.sendPromptShouldFail = true

        await coordinator.sendMessage(context: mockContext)

        let afterState = InputBarState()
        let hasDraftAfter = await store.loadDraft(sessionId: "test-session", into: afterState)
        XCTAssertFalse(hasDraftAfter)

        store.removeAllDraftFiles()
        try? await db.clearAll()
        await db.close()
    }
}
