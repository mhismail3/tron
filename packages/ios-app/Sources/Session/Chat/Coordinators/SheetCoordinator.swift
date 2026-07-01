import Foundation
import Observation

/// Manages sheet presentation state for ChatView.
/// Uses single sheet(item:) modifier pattern per SwiftUI best practices.
/// This centralizes all sheet presentation logic and avoids compiler type-checking issues.
@Observable
@MainActor
final class SheetCoordinator {
    /// Currently active sheet (nil = no sheet presented)
    var activeSheet: ChatSheet? {
        didSet {
            if oldValue != activeSheet {
                lastActiveSheet = oldValue
            }
        }
    }

    /// Last active sheet before dismissal/change (used to infer what was dismissed)
    var lastActiveSheet: ChatSheet?

    /// Dismissal callback (called by SwiftUI when sheet dismisses)
    var onDismiss: (() -> Void)?

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
        onDismiss?()
        onDismiss = nil
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
    func showThinkingDetail(_ content: String) {
        present(.thinkingDetail(content))
    }

    /// Show context-control overview or a specific action audit detail.
    func showContextControl(actionResourceId: String? = nil) {
        present(.contextControl(ContextControlSheetData(initialActionResourceId: actionResourceId)))
    }

    /// Show capability invocation detail sheet
    func showCapabilityInvocationDetail(_ data: CapabilityInvocationData) {
        present(.capabilityInvocationDetail(data))
    }

}
