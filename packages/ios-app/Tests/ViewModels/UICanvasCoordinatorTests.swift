import XCTest
@testable import TronMobile

/// Tests for UICanvasCoordinator
/// Following TDD - tests written FIRST before implementation verification
@MainActor
final class UICanvasCoordinatorTests: XCTestCase {

    private var coordinator: UICanvasCoordinator!
    private var mockContext: MockUICanvasContext!

    override func setUp() async throws {
        coordinator = UICanvasCoordinator()
        mockContext = MockUICanvasContext()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - handleUIRenderStart Tests

    func testRenderStartUpdatesExistingChipToRendering() {
        // Given - chip already exists (created by tool_start)
        let chipData = RenderAppUIChipData(
            toolCallId: "tool_123",
            canvasId: "canvas_1",
            title: "Test App",
            status: .rendering,
            errorMessage: nil
        )
        let message = ChatMessage(role: .assistant, content: .renderAppUI(chipData))
        mockContext.messages = [message]
        mockContext.renderAppUIChipTracker.createChipFromToolStart(
            canvasId: "canvas_1",
            messageId: message.id,
            toolCallId: "tool_123",
            title: "Test App"
        )

        // When
        let event = UIRenderStartPlugin.Result(
            canvasId: "canvas_1",
            title: "Test App",
            toolCallId: "tool_123"
        )
        coordinator.handleUIRenderStart(event, context: mockContext)

        // Then
        if case .renderAppUI(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.status, .rendering)
            XCTAssertEqual(data.canvasId, "canvas_1")
        } else {
            XCTFail("Expected renderAppUI content")
        }
    }

    func testRenderStartStoresPendingEventWhenNoChip() {
        // Given - no chip exists yet (ui.render.start before tool.start)
        mockContext.messages = []

        // When
        let event = UIRenderStartPlugin.Result(
            canvasId: "canvas_1",
            title: "Test App",
            toolCallId: "tool_123"
        )
        coordinator.handleUIRenderStart(event, context: mockContext)

        // Then - event should be stored as pending
        let pending = mockContext.renderAppUIChipTracker.consumePendingRenderStart(toolCallId: "tool_123")
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.canvasId, "canvas_1")
    }

    func testRenderStartStartsCanvasState() {
        // Given
        let chipData = RenderAppUIChipData(
            toolCallId: "tool_123",
            canvasId: "canvas_1",
            title: "Test App",
            status: .rendering,
            errorMessage: nil
        )
        let message = ChatMessage(role: .assistant, content: .renderAppUI(chipData))
        mockContext.messages = [message]
        mockContext.renderAppUIChipTracker.createChipFromToolStart(
            canvasId: "canvas_1",
            messageId: message.id,
            toolCallId: "tool_123",
            title: "Test App"
        )

        // When
        let event = UIRenderStartPlugin.Result(
            canvasId: "canvas_1",
            title: "Test App",
            toolCallId: "tool_123"
        )
        coordinator.handleUIRenderStart(event, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.uiCanvasState.hasCanvas("canvas_1"))
    }

    // MARK: - handleUIRenderChunk Tests

    func testRenderChunkCreatesChipOnFirstChunk() {
        // Given - no chip exists yet (chunk arrived before tool_start)
        mockContext.messages = []

        // When
        let event = UIRenderChunkPlugin.Result(
            canvasId: "canvas_1",
            chunk: "{\"type\":",
            accumulated: "{\"canvasId\": \"canvas_1\", \"title\": \"My App\", \"type\":"
        )
        coordinator.handleUIRenderChunk(event, context: mockContext)

        // Then - chip should be created
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .renderAppUI(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.canvasId, "canvas_1")
            XCTAssertEqual(data.title, "My App")
            XCTAssertEqual(data.status, .rendering)
            XCTAssertTrue(data.toolCallId.hasPrefix("pending_"))
        } else {
            XCTFail("Expected renderAppUI content")
        }
    }

    func testRenderChunkExtractsTitleFromAccumulated() {
        // Given
        mockContext.messages = []

        // When
        let event = UIRenderChunkPlugin.Result(
            canvasId: "canvas_1",
            chunk: "chunk",
            accumulated: "{\"canvasId\": \"canvas_1\", \"title\": \"Extracted Title\", \"ui\":"
        )
        coordinator.handleUIRenderChunk(event, context: mockContext)

        // Then
        if case .renderAppUI(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.title, "Extracted Title")
        } else {
            XCTFail("Expected renderAppUI content")
        }
    }

    func testRenderChunkMakesChipVisible() {
        // Given
        mockContext.messages = []

        // When
        let event = UIRenderChunkPlugin.Result(
            canvasId: "canvas_1",
            chunk: "chunk",
            accumulated: "{\"canvasId\": \"canvas_1\"}"
        )
        coordinator.handleUIRenderChunk(event, context: mockContext)

        // Then - verify the placeholder toolCallId was marked visible
        XCTAssertTrue(mockContext.animationCoordinator.visibleToolCallIds.contains("pending_canvas_1"))
    }

    func testRenderChunkAppendsToMessageWindow() {
        // Given
        mockContext.messages = []

        // When
        let event = UIRenderChunkPlugin.Result(
            canvasId: "canvas_1",
            chunk: "chunk",
            accumulated: "{\"canvasId\": \"canvas_1\"}"
        )
        coordinator.handleUIRenderChunk(event, context: mockContext)

        // Then - verify message was created (appendMessage syncs this to window manager)
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .renderAppUI = mockContext.messages[0].content {
            // Message was appended and synced to MessageWindowManager
        } else {
            XCTFail("Expected renderAppUI message to be appended")
        }
    }

    func testRenderChunkCreatesCanvasStateIfMissing() {
        // Given - chip exists but canvas state doesn't (tool_start arrived first)
        let chipData = RenderAppUIChipData(
            toolCallId: "tool_123",
            canvasId: "canvas_1",
            title: "Test App",
            status: .rendering,
            errorMessage: nil
        )
        let message = ChatMessage(role: .assistant, content: .renderAppUI(chipData))
        mockContext.messages = [message]
        mockContext.renderAppUIChipTracker.createChipFromToolStart(
            canvasId: "canvas_1",
            messageId: message.id,
            toolCallId: "tool_123",
            title: "Test App"
        )
        // Note: NOT calling uiCanvasState.startRender - simulating tool_start not creating canvas

        // When
        let event = UIRenderChunkPlugin.Result(
            canvasId: "canvas_1",
            chunk: "chunk",
            accumulated: "{\"canvasId\": \"canvas_1\"}"
        )
        coordinator.handleUIRenderChunk(event, context: mockContext)

        // Then - canvas should be created
        XCTAssertTrue(mockContext.uiCanvasState.hasCanvas("canvas_1"))
    }

    func testRenderChunkUpdatesExistingCanvas() {
        // Given - canvas already exists
        mockContext.uiCanvasState.startRender(canvasId: "canvas_1", title: "Test", toolCallId: "tool_123")
        mockContext.renderAppUIChipTracker.createChipFromToolStart(
            canvasId: "canvas_1",
            messageId: UUID(),
            toolCallId: "tool_123",
            title: "Test"
        )

        // When
        let event = UIRenderChunkPlugin.Result(
            canvasId: "canvas_1",
            chunk: "new chunk",
            accumulated: "{\"canvasId\": \"canvas_1\", \"data\": \"accumulated\"}"
        )
        coordinator.handleUIRenderChunk(event, context: mockContext)

        // Then - canvas should be updated (not error)
        XCTAssertTrue(mockContext.uiCanvasState.hasCanvas("canvas_1"))
    }

    // MARK: - handleUIRenderComplete Tests

    func testRenderCompleteUpdatesChipToComplete() {
        // Given
        let chipData = RenderAppUIChipData(
            toolCallId: "tool_123",
            canvasId: "canvas_1",
            title: "Test App",
            status: .rendering,
            errorMessage: nil
        )
        let message = ChatMessage(role: .assistant, content: .renderAppUI(chipData))
        mockContext.messages = [message]
        mockContext.renderAppUIChipTracker.createChipFromToolStart(
            canvasId: "canvas_1",
            messageId: message.id,
            toolCallId: "tool_123",
            title: "Test App"
        )
        mockContext.uiCanvasState.startRender(canvasId: "canvas_1", title: "Test App", toolCallId: "tool_123")

        // When
        let event = UIRenderCompletePlugin.Result(
            canvasId: "canvas_1",
            ui: ["type": AnyCodable("text"), "text": AnyCodable("Hello")],
            state: nil
        )
        coordinator.handleUIRenderComplete(event, context: mockContext)

        // Then
        if case .renderAppUI(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.status, .complete)
            XCTAssertNil(data.errorMessage)
        } else {
            XCTFail("Expected renderAppUI content")
        }
    }

    func testRenderCompleteHandlesNilUI() {
        // Given
        let chipData = RenderAppUIChipData(
            toolCallId: "tool_123",
            canvasId: "canvas_1",
            title: "Test App",
            status: .rendering,
            errorMessage: nil
        )
        let message = ChatMessage(role: .assistant, content: .renderAppUI(chipData))
        mockContext.messages = [message]
        mockContext.renderAppUIChipTracker.createChipFromToolStart(
            canvasId: "canvas_1",
            messageId: message.id,
            toolCallId: "tool_123",
            title: "Test App"
        )

        // When
        let event = UIRenderCompletePlugin.Result(
            canvasId: "canvas_1",
            ui: nil,
            state: nil
        )
        coordinator.handleUIRenderComplete(event, context: mockContext)

        // Then - should log error but not crash
        XCTAssertTrue(mockContext.logErrorCalled)
    }

    // MARK: - handleUIRenderError Tests

    func testRenderErrorUpdatesChipToError() {
        // Given
        let chipData = RenderAppUIChipData(
            toolCallId: "tool_123",
            canvasId: "canvas_1",
            title: "Test App",
            status: .rendering,
            errorMessage: nil
        )
        let message = ChatMessage(role: .assistant, content: .renderAppUI(chipData))
        mockContext.messages = [message]
        mockContext.renderAppUIChipTracker.createChipFromToolStart(
            canvasId: "canvas_1",
            messageId: message.id,
            toolCallId: "tool_123",
            title: "Test App"
        )
        mockContext.uiCanvasState.startRender(canvasId: "canvas_1", title: "Test App", toolCallId: "tool_123")

        // When
        let event = UIRenderErrorPlugin.Result(
            canvasId: "canvas_1",
            error: "Render failed"
        )
        coordinator.handleUIRenderError(event, context: mockContext)

        // Then
        if case .renderAppUI(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.status, .error)
            XCTAssertEqual(data.errorMessage, "Render failed")
        } else {
            XCTFail("Expected renderAppUI content")
        }
    }

    func testRenderErrorMarksCanvasAsErrored() {
        // Given
        mockContext.uiCanvasState.startRender(canvasId: "canvas_1", title: "Test", toolCallId: "tool_123")

        // When
        let event = UIRenderErrorPlugin.Result(
            canvasId: "canvas_1",
            error: "Render failed"
        )
        coordinator.handleUIRenderError(event, context: mockContext)

        // Then
        if let canvas = mockContext.uiCanvasState.canvases["canvas_1"],
           case .error(let errorMsg) = canvas.status {
            XCTAssertEqual(errorMsg, "Render failed")
        } else {
            XCTFail("Expected error status on canvas")
        }
    }

    // MARK: - handleUIRenderRetry Tests

    func testRenderRetryUpdatesChipToError() {
        // Given
        let chipData = RenderAppUIChipData(
            toolCallId: "tool_123",
            canvasId: "canvas_1",
            title: "Test App",
            status: .rendering,
            errorMessage: nil
        )
        let message = ChatMessage(role: .assistant, content: .renderAppUI(chipData))
        mockContext.messages = [message]
        mockContext.renderAppUIChipTracker.createChipFromToolStart(
            canvasId: "canvas_1",
            messageId: message.id,
            toolCallId: "tool_123",
            title: "Test App"
        )
        mockContext.uiCanvasState.startRender(canvasId: "canvas_1", title: "Test App", toolCallId: "tool_123")

        // When
        let event = UIRenderRetryPlugin.Result(
            canvasId: "canvas_1",
            attempt: 2,
            errors: "Validation failed"
        )
        coordinator.handleUIRenderRetry(event, context: mockContext)

        // Then
        if case .renderAppUI(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.status, .error)
            XCTAssertEqual(data.errorMessage, "Error generating")
        } else {
            XCTFail("Expected renderAppUI content")
        }
    }

    func testRenderRetrySetsCanvasRetrying() {
        // Given
        mockContext.uiCanvasState.startRender(canvasId: "canvas_1", title: "Test", toolCallId: "tool_123")

        // When
        let event = UIRenderRetryPlugin.Result(
            canvasId: "canvas_1",
            attempt: 2,
            errors: "Validation failed"
        )
        coordinator.handleUIRenderRetry(event, context: mockContext)

        // Then
        if let canvas = mockContext.uiCanvasState.canvases["canvas_1"],
           case .retrying(let attempt, _) = canvas.status {
            XCTAssertEqual(attempt, 2)
        } else {
            XCTFail("Expected retrying status on canvas")
        }
    }

    // MARK: - Title Extraction Tests

    func testExtractsTitleWithEscapedCharacters() {
        // Given
        mockContext.messages = []

        // When
        let event = UIRenderChunkPlugin.Result(
            canvasId: "canvas_1",
            chunk: "chunk",
            accumulated: "{\"title\": \"Title with \\\"quotes\\\" and \\nnewlines\"}"
        )
        coordinator.handleUIRenderChunk(event, context: mockContext)

        // Then
        if case .renderAppUI(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.title, "Title with \"quotes\" and \nnewlines")
        } else {
            XCTFail("Expected renderAppUI content")
        }
    }

    func testHandlesMissingTitle() {
        // Given
        mockContext.messages = []

        // When
        let event = UIRenderChunkPlugin.Result(
            canvasId: "canvas_1",
            chunk: "chunk",
            accumulated: "{\"canvasId\": \"canvas_1\", \"ui\": {}}"
        )
        coordinator.handleUIRenderChunk(event, context: mockContext)

        // Then
        if case .renderAppUI(let data) = mockContext.messages[0].content {
            XCTAssertNil(data.title)
        } else {
            XCTFail("Expected renderAppUI content")
        }
    }
}

// MARK: - Mock Context

@MainActor
final class MockUICanvasContext: UICanvasContext {
    // MARK: - State
    var messages: [ChatMessage] = []
    var renderAppUIChipTracker = RenderAppUIChipTracker()
    var uiCanvasState = UICanvasState()
    var animationCoordinator = AnimationCoordinator()
    var messageWindowManager = MessageWindowManager()

    // MARK: - Call tracking
    var logErrorCalled = false

    // MARK: - Logging
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {
        logErrorCalled = true
    }
}
