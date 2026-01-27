import Foundation

/// State struct managing sheet visibility and data for ChatView.
/// Consolidates 8+ sheet-related @State properties into a single struct.
struct SheetState {
    // MARK: - Visibility Flags

    /// Show context audit sheet
    var showContextAudit = false

    /// Show session history sheet
    var showSessionHistory = false

    /// Show skill detail sheet
    var showSkillDetailSheet = false

    /// Show compaction detail sheet
    var showCompactionDetail = false

    // MARK: - Sheet Data

    /// Skill to show in detail sheet
    var skillForDetailSheet: Skill?

    /// Mode for skill detail (skill vs spell)
    var skillDetailMode: ChipMode = .skill

    /// Data for compaction detail sheet
    var compactionDetailData: CompactionDetailData?

    /// Data for notify app sheet
    var notifyAppSheetData: NotifyAppChipData?

    /// Content for thinking detail sheet
    var thinkingSheetContent: String?

    // MARK: - Compaction Detail Data

    struct CompactionDetailData {
        let tokensBefore: Int
        let tokensAfter: Int
        let reason: String
        let summary: String?
    }

    // MARK: - Presentation Helpers

    /// Present skill detail sheet with skill and mode
    mutating func presentSkillDetail(_ skill: Skill, mode: ChipMode) {
        skillForDetailSheet = skill
        skillDetailMode = mode
        showSkillDetailSheet = true
    }

    /// Present compaction detail sheet
    mutating func presentCompactionDetail(
        tokensBefore: Int,
        tokensAfter: Int,
        reason: String,
        summary: String?
    ) {
        compactionDetailData = CompactionDetailData(
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            reason: reason,
            summary: summary
        )
        showCompactionDetail = true
    }

    /// Present notify app sheet
    mutating func presentNotifyApp(_ data: NotifyAppChipData) {
        notifyAppSheetData = data
    }

    /// Present thinking detail sheet
    mutating func presentThinkingDetail(_ content: String) {
        thinkingSheetContent = content
    }

    /// Dismiss all sheets and clear data
    mutating func dismissAll() {
        showContextAudit = false
        showSessionHistory = false
        showSkillDetailSheet = false
        showCompactionDetail = false
        skillForDetailSheet = nil
        skillDetailMode = .skill
        compactionDetailData = nil
        notifyAppSheetData = nil
        thinkingSheetContent = nil
    }

    // MARK: - Binding Helpers (for sheet modifiers)

    /// Binding-like property for skill detail sheet presentation
    var skillDetailSheetPresented: Bool {
        get { showSkillDetailSheet }
        set {
            showSkillDetailSheet = newValue
            if !newValue {
                skillForDetailSheet = nil
            }
        }
    }

    /// Binding-like property for compaction detail sheet presentation
    var compactionDetailPresented: Bool {
        get { showCompactionDetail }
        set {
            showCompactionDetail = newValue
            if !newValue {
                compactionDetailData = nil
            }
        }
    }

    /// Binding-like property for notify app sheet presentation
    var notifyAppSheetPresented: Bool {
        get { notifyAppSheetData != nil }
        set {
            if !newValue {
                notifyAppSheetData = nil
            }
        }
    }

    /// Binding-like property for thinking sheet presentation
    var thinkingSheetPresented: Bool {
        get { thinkingSheetContent != nil }
        set {
            if !newValue {
                thinkingSheetContent = nil
            }
        }
    }
}
