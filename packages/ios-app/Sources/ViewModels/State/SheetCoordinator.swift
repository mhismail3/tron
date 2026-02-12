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

    /// Show Safari with URL
    func showSafari(_ url: URL) {
        present(.safari(url))
    }

    /// Show browser window
    func showBrowser() {
        present(.browser)
    }

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
        summary: String?
    ) {
        present(.compactionDetail(CompactionDetailData(
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            reason: reason,
            summary: summary
        )))
    }

    /// Show memory detail sheet
    func showMemoryDetail(title: String, entryType: String, sessionId: String) {
        present(.memoryDetail(MemoryDetailData(title: title, entryType: entryType, sessionId: sessionId)))
    }

    /// Show provider error detail sheet
    func showProviderErrorDetail(provider: String, category: String, message: String, suggestion: String?, retryable: Bool) {
        present(.providerErrorDetail(ProviderErrorDetailData(
            provider: provider,
            category: category,
            message: message,
            suggestion: suggestion,
            retryable: retryable
        )))
    }

    /// Show ask user question sheet
    func showAskUserQuestion() {
        present(.askUserQuestion)
    }

    /// Show subagent detail sheet
    func showSubagentDetail() {
        present(.subagentDetail)
    }

    /// Show UI canvas sheet
    func showUICanvas() {
        present(.uiCanvas)
    }

    /// Show task list sheet (from toolbar menu)
    func showTaskList() {
        present(.taskList)
    }

    /// Show task detail sheet (from chip tap, with tool result data)
    func showTaskDetail(_ data: TaskManagerChipData) {
        present(.taskDetail(data))
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
    func showCommandToolDetail(_ data: CommandToolChipData) {
        present(.commandToolDetail(data))
    }

    /// Show model picker sheet
    func showModelPicker() {
        present(.modelPicker)
    }
}
