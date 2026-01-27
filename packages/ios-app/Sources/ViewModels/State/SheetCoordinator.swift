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

    /// Show todo list sheet
    func showTodoList() {
        present(.todoList)
    }

    /// Show notify app detail sheet
    func showNotifyApp(_ data: NotifyAppChipData) {
        present(.notifyApp(data))
    }

    /// Show thinking detail sheet
    func showThinkingDetail(_ content: String) {
        present(.thinkingDetail(content))
    }
}
