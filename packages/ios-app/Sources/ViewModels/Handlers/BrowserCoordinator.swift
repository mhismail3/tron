import Foundation
import UIKit

/// Protocol defining the context required by BrowserCoordinator.
///
/// This protocol allows BrowserCoordinator to be tested independently from ChatViewModel
/// by defining the minimum interface it needs to interact with browser state and RPC calls.
///
/// Inherits from:
/// - LoggingContext: Logging and error display (showError)
@MainActor
protocol BrowserEventContext: LoggingContext {
    /// Browser state container
    var browserState: BrowserState { get }

    /// Current session ID (nil if no active session)
    var currentSessionId: String? { get }

    /// RPC: Get browser status from server
    func getBrowserStatus() async throws -> BrowserGetStatusResult

    /// RPC: Start browser streaming
    func startBrowserStreamRPC() async throws -> Bool

    /// RPC: Stop browser streaming
    func stopBrowserStreamRPC() async throws
}

/// Coordinates browser event handling and session lifecycle for ChatViewModel.
///
/// Responsibilities:
/// - Handling browser frame events from screencast streaming
/// - Managing browser window visibility (auto-show on first frame)
/// - Tracking user dismissal to prevent unwanted auto-reopens
/// - Browser session lifecycle (start/stop streaming, close session)
/// - Browser status queries
///
/// This coordinator extracts browser handling logic from ChatViewModel+Browser.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class BrowserCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Browser Frame Handling

    /// Handle incoming browser frame from screencast.
    ///
    /// - Parameters:
    ///   - frameData: Base64-encoded JPEG frame data
    ///   - context: The context providing access to state and dependencies
    func handleBrowserFrame(frameData: String, context: BrowserEventContext) {
        // Support data URI prefixes and whitespace/newlines in base64 payloads.
        let cleanedFrameData: String
        if let commaIndex = frameData.firstIndex(of: ","),
           frameData[..<commaIndex].contains("base64") {
            cleanedFrameData = String(frameData[frameData.index(after: commaIndex)...])
        } else {
            cleanedFrameData = frameData
        }

        // Decode base64 JPEG - this is fast enough to do on main thread
        // Streaming at ~10 FPS means ~100ms per frame budget, JPEG decode is <5ms
        guard let data = Data(base64Encoded: cleanedFrameData, options: [.ignoreUnknownCharacters]),
              let image = UIImage(data: data) else {
            context.logDebug("Failed to decode browser frame data")
            return
        }

        context.browserState.browserFrame = image

        // Update browserStatus to reflect that we have an active streaming session
        // This handles the case where BrowserDelegate auto-started streaming
        let wasFirstFrame = context.browserState.browserStatus == nil ||
                           context.browserState.browserStatus?.isStreaming != true
        if wasFirstFrame {
            context.browserState.browserStatus = BrowserGetStatusResult(
                hasBrowser: true,
                isStreaming: true,
                currentUrl: context.browserState.browserStatus?.currentUrl
            )
        }

        // Auto-show browser window only on the FIRST frame, and only if user hasn't
        // manually dismissed it during this prompt/response cycle
        if wasFirstFrame && !context.browserState.showBrowserWindow &&
           context.browserState.dismissal != .userDismissed {
            context.browserState.showBrowserWindow = true
            context.logInfo("Browser window auto-shown on first frame")
        }
    }

    // MARK: - User Interactions

    /// Mark browser as dismissed by user (prevents auto-reopen this turn).
    ///
    /// - Parameter context: The context providing access to state
    func userDismissedBrowser(context: BrowserEventContext) {
        context.browserState.dismissal = .userDismissed
        context.browserState.showBrowserWindow = false
        context.logInfo("User dismissed browser sheet - won't auto-reopen this turn")
    }

    /// Toggle browser window visibility (explicit user action via globe button).
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func toggleBrowserWindow(context: BrowserEventContext) {
        if context.browserState.showBrowserWindow {
            // User is closing via globe - same as dismissing
            userDismissedBrowser(context: context)
        } else if hasBrowserSession(context: context) {
            // User explicitly wants to see browser - override the dismiss flag
            context.browserState.showBrowserWindow = true
            // Start streaming if not already
            if context.browserState.browserStatus?.isStreaming != true {
                Task {
                    await startBrowserStream(context: context)
                }
            }
        }
    }

    // MARK: - Browser Session Lifecycle

    /// Handle browser session closed event.
    ///
    /// - Parameters:
    ///   - sessionId: The ID of the closed session
    ///   - context: The context providing access to state
    func handleBrowserClosed(_ sessionId: String, context: BrowserEventContext) {
        context.browserState.browserFrame = nil
        context.browserState.browserStatus = nil
        context.browserState.showBrowserWindow = false
        context.logInfo("Browser session closed: \(sessionId)")
    }

    /// Close the browser session entirely (stops streaming and clears state).
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func closeBrowserSession(context: BrowserEventContext) async {
        context.logInfo("Closing browser session")
        // Stop streaming first (handles its own errors internally)
        await stopBrowserStream(context: context)
        // Clear all browser state
        context.browserState.browserFrame = nil
        context.browserState.browserStatus = nil
        context.browserState.showBrowserWindow = false
        context.logDebug("Browser session closed successfully")
    }

    // MARK: - Browser API

    /// Request browser status from server.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func requestBrowserStatus(context: BrowserEventContext) async {
        guard context.currentSessionId != nil else { return }

        do {
            let status = try await context.getBrowserStatus()
            context.browserState.browserStatus = status
        } catch {
            context.logError("Failed to get browser status: \(error)")
        }
    }

    /// Start browser streaming.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func startBrowserStream(context: BrowserEventContext) async {
        guard context.currentSessionId != nil else { return }

        do {
            let success = try await context.startBrowserStreamRPC()
            if success {
                context.browserState.browserStatus = BrowserGetStatusResult(
                    hasBrowser: true,
                    isStreaming: true,
                    currentUrl: nil
                )
                // Only auto-show if user hasn't manually dismissed this turn
                if context.browserState.dismissal != .userDismissed {
                    context.browserState.showBrowserWindow = true
                }
                context.logInfo("Browser stream started")
            }
        } catch {
            context.logError("Failed to start browser stream: \(error)")
            context.showError("Failed to start browser stream")
        }
    }

    /// Stop browser streaming.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func stopBrowserStream(context: BrowserEventContext) async {
        guard context.currentSessionId != nil else { return }

        do {
            try await context.stopBrowserStreamRPC()
            context.browserState.browserStatus = BrowserGetStatusResult(
                hasBrowser: context.browserState.browserStatus?.hasBrowser ?? false,
                isStreaming: false,
                currentUrl: context.browserState.browserStatus?.currentUrl
            )
            context.logInfo("Browser stream stopped")
        } catch {
            context.logError("Failed to stop browser stream: \(error)")
        }
    }

    // MARK: - Computed Properties

    /// Whether browser toolbar button should be visible.
    /// Shows if we have an active browser status OR a browser frame to display.
    ///
    /// - Parameter context: The context providing access to state
    /// - Returns: `true` if a browser session is active
    func hasBrowserSession(context: BrowserEventContext) -> Bool {
        (context.browserState.browserStatus?.hasBrowser ?? false) ||
        context.browserState.browserFrame != nil
    }
}
