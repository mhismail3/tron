import XCTest
import UIKit
@testable import TronMobile

/// Tests for BrowserCoordinator - handles browser frame events and session lifecycle
/// Uses TDD: Tests written first, then implementation follows
@MainActor
final class BrowserCoordinatorTests: XCTestCase {

    var coordinator: BrowserCoordinator!
    var mockContext: MockBrowserEventContext!

    override func setUp() async throws {
        mockContext = MockBrowserEventContext()
        coordinator = BrowserCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Browser Frame Handling Tests

    func testHandleBrowserFrameDecodesAndStoresImage() {
        // Given: A valid base64 JPEG frame
        let testImageData = createTestJPEGImage()
        let frameData = testImageData.base64EncodedString()

        // When: Handling browser frame
        coordinator.handleBrowserFrame(frameData: frameData, context: mockContext)

        // Then: Frame should be stored in browserState
        XCTAssertNotNil(mockContext.browserState.browserFrame)
    }

    func testHandleBrowserFrameIgnoresInvalidData() {
        // Given: Invalid base64 data
        let frameData = "not-valid-base64!@#$"

        // When: Handling browser frame
        coordinator.handleBrowserFrame(frameData: frameData, context: mockContext)

        // Then: Frame should remain nil
        XCTAssertNil(mockContext.browserState.browserFrame)
    }

    func testHandleBrowserFrameUpdatesBrowserStatusOnFirstFrame() {
        // Given: No browser status yet
        XCTAssertNil(mockContext.browserState.browserStatus)

        // Given: A valid frame
        let testImageData = createTestJPEGImage()
        let frameData = testImageData.base64EncodedString()

        // When: Handling first frame
        coordinator.handleBrowserFrame(frameData: frameData, context: mockContext)

        // Then: Browser status should be set to streaming
        XCTAssertNotNil(mockContext.browserState.browserStatus)
        XCTAssertTrue(mockContext.browserState.browserStatus?.hasBrowser ?? false)
        XCTAssertTrue(mockContext.browserState.browserStatus?.isStreaming ?? false)
    }

    func testHandleBrowserFrameAutoShowsWindowOnFirstFrame() {
        // Given: Browser window not shown
        XCTAssertFalse(mockContext.browserState.showBrowserWindow)

        // Given: A valid frame
        let testImageData = createTestJPEGImage()
        let frameData = testImageData.base64EncodedString()

        // When: Handling first frame
        coordinator.handleBrowserFrame(frameData: frameData, context: mockContext)

        // Then: Window should auto-show
        XCTAssertTrue(mockContext.browserState.showBrowserWindow)
    }

    func testHandleBrowserFrameDoesNotAutoShowIfUserDismissed() {
        // Given: User dismissed browser this turn
        mockContext.browserState.userDismissedBrowserThisTurn = true

        // Given: A valid frame
        let testImageData = createTestJPEGImage()
        let frameData = testImageData.base64EncodedString()

        // When: Handling frame
        coordinator.handleBrowserFrame(frameData: frameData, context: mockContext)

        // Then: Window should NOT auto-show
        XCTAssertFalse(mockContext.browserState.showBrowserWindow)
    }

    func testHandleBrowserFramePreservesUrlOnStatusUpdate() {
        // Given: Existing browser status with URL
        mockContext.browserState.browserStatus = BrowserGetStatusResult(
            hasBrowser: true,
            isStreaming: false,
            currentUrl: "https://example.com"
        )

        // Given: A valid frame
        let testImageData = createTestJPEGImage()
        let frameData = testImageData.base64EncodedString()

        // When: Handling frame
        coordinator.handleBrowserFrame(frameData: frameData, context: mockContext)

        // Then: URL should be preserved
        XCTAssertEqual(mockContext.browserState.browserStatus?.currentUrl, "https://example.com")
    }

    // MARK: - User Interaction Tests

    func testUserDismissedBrowserSetsFlag() {
        // When: User dismisses browser
        coordinator.userDismissedBrowser(context: mockContext)

        // Then: Flag should be set
        XCTAssertTrue(mockContext.browserState.userDismissedBrowserThisTurn)
    }

    func testUserDismissedBrowserHidesWindow() {
        // Given: Browser window is shown
        mockContext.browserState.showBrowserWindow = true

        // When: User dismisses browser
        coordinator.userDismissedBrowser(context: mockContext)

        // Then: Window should be hidden
        XCTAssertFalse(mockContext.browserState.showBrowserWindow)
    }

    func testToggleBrowserWindowHidesWhenShown() {
        // Given: Browser window is shown
        mockContext.browserState.showBrowserWindow = true

        // When: Toggling
        coordinator.toggleBrowserWindow(context: mockContext)

        // Then: Should hide (like dismiss)
        XCTAssertFalse(mockContext.browserState.showBrowserWindow)
        XCTAssertTrue(mockContext.browserState.userDismissedBrowserThisTurn)
    }

    func testToggleBrowserWindowShowsWhenHasBrowserSession() {
        // Given: Browser window is hidden but has session
        mockContext.browserState.showBrowserWindow = false
        mockContext.browserState.browserStatus = BrowserGetStatusResult(
            hasBrowser: true,
            isStreaming: false,
            currentUrl: nil
        )

        // When: Toggling
        coordinator.toggleBrowserWindow(context: mockContext)

        // Then: Should show
        XCTAssertTrue(mockContext.browserState.showBrowserWindow)
    }

    func testToggleBrowserWindowRequestsStreamingWhenNotStreaming() async {
        // Given: Has browser but not streaming
        mockContext.browserState.showBrowserWindow = false
        mockContext.browserState.browserStatus = BrowserGetStatusResult(
            hasBrowser: true,
            isStreaming: false,
            currentUrl: nil
        )

        // When: Toggling
        coordinator.toggleBrowserWindow(context: mockContext)

        // Allow Task to execute (toggleBrowserWindow starts stream in detached Task)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Then: Should request stream start
        XCTAssertTrue(mockContext.startBrowserStreamCalled)
    }

    // MARK: - Browser Session Lifecycle Tests

    func testHandleBrowserClosedClearsState() {
        // Given: Active browser state
        mockContext.browserState.browserFrame = UIImage()
        mockContext.browserState.browserStatus = BrowserGetStatusResult(
            hasBrowser: true,
            isStreaming: true,
            currentUrl: nil
        )
        mockContext.browserState.showBrowserWindow = true

        // When: Browser session closes
        coordinator.handleBrowserClosed("session_123", context: mockContext)

        // Then: All state should be cleared
        XCTAssertNil(mockContext.browserState.browserFrame)
        XCTAssertNil(mockContext.browserState.browserStatus)
        XCTAssertFalse(mockContext.browserState.showBrowserWindow)
    }

    func testCloseBrowserSessionStopsStreamingAndClearsState() async {
        // Given: Active browser state
        mockContext.browserState.browserFrame = UIImage()
        mockContext.browserState.browserStatus = BrowserGetStatusResult(
            hasBrowser: true,
            isStreaming: true,
            currentUrl: nil
        )
        mockContext.browserState.showBrowserWindow = true

        // When: Closing browser session
        await coordinator.closeBrowserSession(context: mockContext)

        // Then: Should stop stream
        XCTAssertTrue(mockContext.stopBrowserStreamCalled)

        // Then: State should be cleared
        XCTAssertNil(mockContext.browserState.browserFrame)
        XCTAssertNil(mockContext.browserState.browserStatus)
        XCTAssertFalse(mockContext.browserState.showBrowserWindow)
    }

    // MARK: - Browser API Tests

    func testRequestBrowserStatusUpdatesState() async {
        // Given: Mock context will return status
        mockContext.mockBrowserStatus = BrowserGetStatusResult(
            hasBrowser: true,
            isStreaming: false,
            currentUrl: "https://test.com"
        )

        // When: Requesting status
        await coordinator.requestBrowserStatus(context: mockContext)

        // Then: Status should be updated
        XCTAssertEqual(mockContext.browserState.browserStatus?.hasBrowser, true)
        XCTAssertEqual(mockContext.browserState.browserStatus?.currentUrl, "https://test.com")
    }

    func testStartBrowserStreamUpdatesStatusAndShowsWindow() async {
        // Given: No browser status yet
        mockContext.startBrowserStreamSuccess = true

        // When: Starting stream
        await coordinator.startBrowserStream(context: mockContext)

        // Then: Status should show streaming
        XCTAssertTrue(mockContext.browserState.browserStatus?.isStreaming ?? false)

        // Then: Window should be shown
        XCTAssertTrue(mockContext.browserState.showBrowserWindow)
    }

    func testStartBrowserStreamDoesNotAutoShowIfUserDismissed() async {
        // Given: User dismissed this turn
        mockContext.browserState.userDismissedBrowserThisTurn = true
        mockContext.startBrowserStreamSuccess = true

        // When: Starting stream
        await coordinator.startBrowserStream(context: mockContext)

        // Then: Window should NOT be shown
        XCTAssertFalse(mockContext.browserState.showBrowserWindow)
    }

    func testStopBrowserStreamUpdatesStatus() async {
        // Given: Currently streaming
        mockContext.browserState.browserStatus = BrowserGetStatusResult(
            hasBrowser: true,
            isStreaming: true,
            currentUrl: "https://example.com"
        )

        // When: Stopping stream
        await coordinator.stopBrowserStream(context: mockContext)

        // Then: Should no longer be streaming but hasBrowser preserved
        XCTAssertTrue(mockContext.browserState.browserStatus?.hasBrowser ?? false)
        XCTAssertFalse(mockContext.browserState.browserStatus?.isStreaming ?? true)
        XCTAssertEqual(mockContext.browserState.browserStatus?.currentUrl, "https://example.com")
    }

    // MARK: - Computed Properties Tests

    func testHasBrowserSessionWithFrame() {
        // Given: Just a frame, no status
        mockContext.browserState.browserFrame = UIImage()

        // Then: Should have browser session
        XCTAssertTrue(coordinator.hasBrowserSession(context: mockContext))
    }

    func testHasBrowserSessionWithStatus() {
        // Given: Just status, no frame
        mockContext.browserState.browserStatus = BrowserGetStatusResult(
            hasBrowser: true,
            isStreaming: false,
            currentUrl: nil
        )

        // Then: Should have browser session
        XCTAssertTrue(coordinator.hasBrowserSession(context: mockContext))
    }

    func testHasBrowserSessionWithoutFrameOrStatus() {
        // Given: No frame or status

        // Then: Should NOT have browser session
        XCTAssertFalse(coordinator.hasBrowserSession(context: mockContext))
    }

    // MARK: - Helpers

    private func createTestJPEGImage() -> Data {
        // Create a minimal 1x1 red JPEG image
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.5) ?? Data()
    }
}

// MARK: - Mock Context

/// Mock implementation of BrowserEventContext for testing
@MainActor
final class MockBrowserEventContext: BrowserEventContext {
    // MARK: - State
    let browserState = BrowserState()

    // MARK: - Mock RPC Responses
    var mockBrowserStatus: BrowserGetStatusResult?
    var startBrowserStreamSuccess = false

    // MARK: - Tracking for Assertions
    var startBrowserStreamCalled = false
    var stopBrowserStreamCalled = false
    var showErrorCalled = false
    var lastErrorMessage: String?

    // MARK: - Protocol Properties
    var currentSessionId: String? = "test_session"

    // MARK: - Protocol Methods

    func getBrowserStatus() async throws -> BrowserGetStatusResult {
        if let status = mockBrowserStatus {
            return status
        }
        throw TestError.notConfigured
    }

    func startBrowserStreamRPC() async throws -> Bool {
        startBrowserStreamCalled = true
        return startBrowserStreamSuccess
    }

    func stopBrowserStreamRPC() async throws {
        stopBrowserStreamCalled = true
    }

    func showError(_ message: String) {
        showErrorCalled = true
        lastErrorMessage = message
    }

    // MARK: - Logging (no-op for tests)
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}

// MARK: - Test Errors

private enum TestError: Error {
    case notConfigured
}
