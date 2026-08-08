import Foundation
import Observation

/// Manages sheet presentation state for ChatView.
/// Uses single sheet(item:) modifier pattern per SwiftUI best practices.
/// This centralizes all sheet presentation logic and avoids compiler type-checking issues.
@Observable
@MainActor
final class SheetCoordinator {
    /// Currently active sheet (nil = no sheet presented)
    var activeSheet: ChatSheet?

    /// Dismissal callback (called by SwiftUI when sheet dismisses)
    var onDismiss: (() -> Void)?
    private var queuedUserInputRequest: UserInputRequest?
    private var userInputDrafts: [String: UserInputDraft] = [:]

    // MARK: - Computed Properties

    /// Whether any sheet is currently presented
    var isPresented: Bool {
        activeSheet != nil
    }

    // MARK: - Core Presentation Methods

    /// Present a sheet with optional dismiss callback
    /// - Parameters:
    ///   - sheet: The sheet to present
    ///   - onDismiss: Optional callback when sheet is dismissed
    func present(_ sheet: ChatSheet, onDismiss: (() -> Void)? = nil) {
        self.activeSheet = sheet
        self.onDismiss = onDismiss
    }

    /// Dismiss the current sheet
    func dismiss() {
        activeSheet = nil
        finishDismissal()
    }

    /// SwiftUI calls this after interactive or programmatic dismissal. It is
    /// idempotent so an explicit dismiss followed by the framework callback
    /// cannot invoke or retain the payload callback twice.
    func presentationDidDismiss() {
        activeSheet = nil
        finishDismissal()
        if let request = queuedUserInputRequest {
            queuedUserInputRequest = nil
            present(.userInput(request))
        }
    }

    private func finishDismissal() {
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    /// Dismiss only when the requested sheet is currently presented.
    func dismissIfActive(_ sheet: ChatSheet) {
        guard activeSheet == sheet else { return }
        dismiss()
    }

    // MARK: - Convenience Presenters

    /// Show settings sheet
    func showSettings() {
        present(.settings)
    }

    /// Show the session's current context telemetry and supported controls.
    func showSessionContext() {
        present(.sessionContext)
    }

    /// Show compaction detail sheet
    func showCompactionDetail(
        tokensBefore: Int,
        tokensAfter: Int,
        reason: String,
        summary: String?,
        preservedTurns: Int? = nil,
        summarizedTurns: Int? = nil
    ) {
        present(.compactionDetail(CompactionDetailData(
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            reason: reason,
            summary: summary,
            preservedTurns: preservedTurns,
            summarizedTurns: summarizedTurns
        )))
    }

    /// Show provider error detail sheet
    func showProviderErrorDetail(_ data: ProviderErrorDetailData) {
        present(.providerErrorDetail(data))
    }

    /// Show local chat error detail sheet.
    func showLocalErrorDetail(title: String, message: String, suggestion: String?) {
        present(.localErrorDetail(LocalErrorDetailData(title: title, message: message, suggestion: suggestion)))
    }

    /// Show thinking detail sheet
    func showThinkingDetail(_ content: String, kind: ThinkingDisplayKind = .thinking) {
        present(.thinkingDetail(ThinkingDetailData(content: content, kind: kind)))
    }

    /// Show tool invocation detail sheet
    func showToolInvocationDetail(_ data: ToolInvocationData) {
        present(.toolInvocationDetail(data))
    }

    /// Show a grouped tool invocation detail sheet.
    func showToolInvocationGroupDetail(_ data: ToolInvocationGroupData) {
        present(.toolInvocationGroupDetail(data))
    }

    func showUserInput(_ request: UserInputRequest) {
        guard activeSheet == nil else {
            if activeSheet != .userInput(request) {
                queuedUserInputRequest = request
            }
            return
        }
        present(.userInput(request))
    }

    func clearUserInput() {
        queuedUserInputRequest = nil
        guard case .userInput? = activeSheet else { return }
        dismiss()
    }

    func userInputDraft(for request: UserInputRequest) -> UserInputDraft {
        guard request.isAnswerable else { return UserInputDraft(request: request) }
        if let draft = userInputDrafts[request.invocationId] {
            return draft
        }
        let draft = UserInputDraft(request: request)
        userInputDrafts[request.invocationId] = draft
        return draft
    }

    func updateUserInputDraft(_ draft: UserInputDraft, invocationId: String) {
        userInputDrafts[invocationId] = draft
    }

    func clearUserInputDraft(invocationId: String) {
        userInputDrafts.removeValue(forKey: invocationId)
    }

}
