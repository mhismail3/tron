import Foundation
import UIKit

// MARK: - BrowserEventContext Conformance

extension ChatViewModel: BrowserEventContext {
    var currentSessionId: String? {
        rpcClient.currentSessionId
    }

    func getBrowserStatus() async throws -> BrowserGetStatusResult {
        guard let sessionId = currentSessionId else {
            throw BrowserCoordinatorError.noSession
        }
        return try await rpcClient.media.getBrowserStatus(sessionId: sessionId)
    }

    func startBrowserStreamRPC() async throws -> Bool {
        guard let sessionId = currentSessionId else {
            throw BrowserCoordinatorError.noSession
        }
        let result = try await rpcClient.media.startBrowserStream(sessionId: sessionId)
        return result.success
    }

    func stopBrowserStreamRPC() async throws {
        guard let sessionId = currentSessionId else {
            throw BrowserCoordinatorError.noSession
        }
        _ = try await rpcClient.media.stopBrowserStream(sessionId: sessionId)
    }

    // showError is implemented in ChatViewModel.swift (shared with AskUserQuestionContext)
}

/// Errors that can occur in browser coordinator operations
enum BrowserCoordinatorError: Error {
    case noSession
}

// MARK: - Browser Methods

extension ChatViewModel {

    // MARK: - Browser Frame Handling

    /// Handle incoming browser frame from screencast (base64-encoded data)
    func handleBrowserFrame(frameData: String) {
        browserCoordinator.handleBrowserFrame(frameData: frameData, context: self)
    }

    // MARK: - User Interactions

    /// Mark browser as dismissed by user (prevents auto-reopen this turn)
    func userDismissedBrowser() {
        browserCoordinator.userDismissedBrowser(context: self)
    }

    /// Toggle browser window visibility (explicit user action via globe button)
    func toggleBrowserWindow() {
        browserCoordinator.toggleBrowserWindow(context: self)
    }

    // MARK: - Browser Session Lifecycle

    /// Handle browser session closed
    func handleBrowserClosed(_ sessionId: String) {
        browserCoordinator.handleBrowserClosed(sessionId, context: self)
    }

    /// Close the browser session entirely (stops streaming and clears state)
    func closeBrowserSession() {
        Task {
            await browserCoordinator.closeBrowserSession(context: self)
        }
    }

    // MARK: - Browser API

    /// Request browser status from server
    func requestBrowserStatus() async {
        await browserCoordinator.requestBrowserStatus(context: self)
    }

    /// Start browser streaming
    func startBrowserStream() async {
        await browserCoordinator.startBrowserStream(context: self)
    }

    /// Stop browser streaming
    func stopBrowserStream() async {
        await browserCoordinator.stopBrowserStream(context: self)
    }

    // MARK: - Computed Properties

    /// Whether browser toolbar button should be visible
    /// Shows if we have an active browser status OR a browser frame to display
    var hasBrowserSession: Bool {
        browserCoordinator.hasBrowserSession(context: self)
    }
}
