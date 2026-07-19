import XCTest
@testable import TronMobile

@MainActor
final class MessagingCoordinatorDraftTests: XCTestCase {
    var coordinator: MessagingCoordinator!
    var mockContext: MockMessagingContext!
    var testState: IsolatedTestState!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "messaging-drafts")
        testState.registerTeardown(with: self)
        mockContext = MockMessagingContext()
        coordinator = MessagingCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
        await testState.cleanup()
    }

    func testSendMessageClearsDraftAfterSend() async {
        let db = testState.makeDatabase(fileName: "clears.db")
        try! await db.initialize()
        try! await db.clearAll()
        let store = DraftStore(eventDatabase: db, documentsURL: testState.documentsURL)
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
    }

    func testSendMessagePreservesDraftOnPreAcceptServerError() async {
        let db = testState.makeDatabase(fileName: "preserves.db")
        try! await db.initialize()
        try! await db.clearAll()
        let store = DraftStore(eventDatabase: db, documentsURL: testState.documentsURL)
        mockContext.draftStore = store

        let draftState = InputBarState()
        draftState.text = "draft"
        await store.saveImmediately(sessionId: "test-session", inputBarState: draftState)

        mockContext.inputText = "Test"
        mockContext.sendPromptShouldFail = true

        await coordinator.sendMessage(context: mockContext)

        let afterState = InputBarState()
        let hasDraftAfter = await store.loadDraft(sessionId: "test-session", into: afterState)
        XCTAssertTrue(hasDraftAfter)
        XCTAssertEqual(afterState.text, "draft")

        store.removeAllDraftFiles()
        try? await db.clearAll()
    }
}
