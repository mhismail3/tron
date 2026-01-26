import Foundation
import UIKit

// MARK: - Browser Methods

extension ChatViewModel {

    // MARK: - Browser Frame Handling

    /// Handle incoming browser frame from screencast
    func handleBrowserFrame(_ event: BrowserFrameEvent) {
        // Decode base64 JPEG - this is fast enough to do on main thread
        // Streaming at ~10 FPS means ~100ms per frame budget, JPEG decode is <5ms
        guard let data = Data(base64Encoded: event.frameData),
              let image = UIImage(data: data) else {
            return
        }

        browserState.browserFrame = image

        // Update browserStatus to reflect that we have an active streaming session
        // This handles the case where BrowserDelegate auto-started streaming
        let wasFirstFrame = browserState.browserStatus == nil || browserState.browserStatus?.isStreaming != true
        if wasFirstFrame {
            browserState.browserStatus = BrowserGetStatusResult(
                hasBrowser: true,
                isStreaming: true,
                currentUrl: browserState.browserStatus?.currentUrl
            )
        }

        // Auto-show browser window only on the FIRST frame, and only if user hasn't
        // manually dismissed it during this prompt/response cycle
        if wasFirstFrame && !browserState.showBrowserWindow && !browserState.userDismissedBrowserThisTurn {
            browserState.showBrowserWindow = true
            logger.info("Browser window auto-shown on first frame", category: .session)
        }
    }

    // MARK: - User Interactions

    /// Mark browser as dismissed by user (prevents auto-reopen this turn)
    func userDismissedBrowser() {
        browserState.userDismissedBrowserThisTurn = true
        browserState.showBrowserWindow = false
        logger.info("User dismissed browser sheet - won't auto-reopen this turn", category: .session)
    }

    /// Toggle browser window visibility (explicit user action via globe button)
    func toggleBrowserWindow() {
        if browserState.showBrowserWindow {
            // User is closing via globe - same as dismissing
            userDismissedBrowser()
        } else if hasBrowserSession {
            // User explicitly wants to see browser - override the dismiss flag
            browserState.showBrowserWindow = true
            // Start streaming if not already
            if browserState.browserStatus?.isStreaming != true {
                Task {
                    await startBrowserStream()
                }
            }
        }
    }

    // MARK: - Browser Session Lifecycle

    /// Handle browser session closed
    func handleBrowserClosed(_ sessionId: String) {
        browserState.browserFrame = nil
        browserState.browserStatus = nil
        browserState.showBrowserWindow = false
        logger.info("Browser session closed: \(sessionId)", category: .session)
    }

    /// Close the browser session entirely (stops streaming and clears state)
    func closeBrowserSession() {
        logger.info("Closing browser session", category: .session)
        Task {
            do {
                // Stop streaming first
                await stopBrowserStream()
                // Clear all browser state
                await MainActor.run {
                    browserState.browserFrame = nil
                    browserState.browserStatus = nil
                    browserState.showBrowserWindow = false
                }
                logger.debug("Browser session closed successfully", category: .session)
            } catch {
                logger.error("Failed to close browser session: \(error.localizedDescription)", category: .session)
            }
        }
    }

    // MARK: - Browser API

    /// Request browser status from server
    func requestBrowserStatus() async {
        guard let sessionId = rpcClient.currentSessionId else { return }

        do {
            let status = try await rpcClient.media.getBrowserStatus(sessionId: sessionId)
            await MainActor.run {
                self.browserState.browserStatus = status
            }
        } catch {
            logger.error("Failed to get browser status: \(error)", category: .session)
        }
    }

    /// Start browser streaming
    func startBrowserStream() async {
        guard let sessionId = rpcClient.currentSessionId else { return }

        do {
            let result = try await rpcClient.media.startBrowserStream(sessionId: sessionId)
            if result.success {
                await MainActor.run {
                    self.browserState.browserStatus = BrowserGetStatusResult(
                        hasBrowser: true,
                        isStreaming: true,
                        currentUrl: nil
                    )
                    // Only auto-show if user hasn't manually dismissed this turn
                    if !self.browserState.userDismissedBrowserThisTurn {
                        self.browserState.showBrowserWindow = true
                    }
                }
                logger.info("Browser stream started", category: .session)
            }
        } catch {
            logger.error("Failed to start browser stream: \(error)", category: .session)
            showErrorAlert("Failed to start browser stream")
        }
    }

    /// Stop browser streaming
    func stopBrowserStream() async {
        guard let sessionId = rpcClient.currentSessionId else { return }

        do {
            _ = try await rpcClient.media.stopBrowserStream(sessionId: sessionId)
            await MainActor.run {
                self.browserState.browserStatus = BrowserGetStatusResult(
                    hasBrowser: self.browserState.browserStatus?.hasBrowser ?? false,
                    isStreaming: false,
                    currentUrl: self.browserState.browserStatus?.currentUrl
                )
            }
            logger.info("Browser stream stopped", category: .session)
        } catch {
            logger.error("Failed to stop browser stream: \(error)", category: .session)
        }
    }

    // MARK: - Computed Properties

    /// Whether browser toolbar button should be visible
    /// Shows if we have an active browser status OR a browser frame to display
    var hasBrowserSession: Bool {
        (browserState.browserStatus?.hasBrowser ?? false) || browserState.browserFrame != nil
    }
}
