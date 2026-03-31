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
    }

    // MARK: - Convenience Presenters

    /// Show settings sheet
    func showSettings() {
        present(.settings)
    }

    /// Show context audit sheet
    func showContextAudit() {
        present(.contextAudit)
    }

    /// Show session history sheet
    func showSessionHistory() {
        present(.sessionHistory)
    }

    /// Show skill/spell detail sheet
    func showSkillDetail(_ skill: Skill, mode: ChipMode) {
        present(.skillDetail(skill, mode))
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

    /// Show memory retain detail sheet
    func showMemoryRetainDetail(title: String, summary: String?) {
        present(.memoryRetainDetail(MemoryRetainDetailData(title: title, summary: summary)))
    }

    /// Show provider error detail sheet
    func showProviderErrorDetail(_ data: ProviderErrorDetailData) {
        present(.providerErrorDetail(data))
    }

    /// Show ask user question sheet
    func showAskUserQuestion() {
        present(.askUserQuestion)
    }

    /// Show get confirmation sheet
    func showGetConfirmation() {
        present(.getConfirmation)
    }

    /// Show subagent detail sheet
    func showSubagentDetail() {
        present(.subagentDetail)
    }

    /// Show notify app detail sheet
    func showNotifyApp(_ data: NotifyAppChipData) {
        present(.notifyApp(data))
    }

    /// Show thinking detail sheet
    func showThinkingDetail(_ content: String) {
        present(.thinkingDetail(content))
    }

    /// Show command tool detail sheet
    func showWaitForAgentsDetail(_ data: WaitForAgentsChipData) {
        present(.waitForAgentsDetail(data))
    }

    func showCommandToolDetail(_ data: CommandToolChipData) {
        present(.commandToolDetail(data))
    }

    /// Show model picker sheet
    func showModelPicker() {
        present(.modelPicker)
    }

    /// Show source changes sheet
    func showSourceChanges() {
        present(.sourceChanges)
    }
}
