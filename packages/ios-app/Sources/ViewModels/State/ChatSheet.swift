import Foundation

/// Data for memory retain detail sheet
struct MemoryRetainDetailData: Equatable {
    let title: String
    let summary: String?
}

/// Data for compaction detail sheet
struct CompactionDetailData: Equatable {
    let tokensBefore: Int
    let tokensAfter: Int
    let reason: String
    let summary: String?
    let preservedTurns: Int?
    let summarizedTurns: Int?

    init(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?, preservedTurns: Int? = nil, summarizedTurns: Int? = nil) {
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.reason = reason
        self.summary = summary
        self.preservedTurns = preservedTurns
        self.summarizedTurns = summarizedTurns
    }
}

/// Data for provider error detail sheet
struct ProviderErrorDetailData: Equatable, Hashable {
    let provider: String
    let category: String
    let message: String
    let suggestion: String?
    let retryable: Bool
    let statusCode: Int?
    let errorType: String?
    let model: String?
}

/// Identifiable enum representing all possible sheets in ChatView.
/// Uses single sheet(item:) modifier pattern per SwiftUI best practices.
/// This avoids Swift compiler type-checking timeout with multiple .sheet() modifiers.
enum ChatSheet: Identifiable, Equatable {
    // Settings & Info
    case settings
    case contextAudit
    case sessionHistory

    // Skill/Spell details
    case skillDetail(Skill, ChipMode)
    case compactionDetail(CompactionDetailData)
    case memoryRetainDetail(MemoryRetainDetailData)

    // Tool sheets
    case askUserQuestion
    case getConfirmation
    case subagentDetail

    // Notification sheets
    case notifyApp(NotifyAppChipData)
    case thinkingDetail(String)
    case providerErrorDetail(ProviderErrorDetailData)

    // Command tool detail
    case commandToolDetail(CommandToolChipData)

    // Model picker
    case modelPicker

    // Source changes
    case sourceChanges

    var id: String {
        switch self {
        case .settings:
            return "settings"
        case .contextAudit:
            return "contextAudit"
        case .sessionHistory:
            return "sessionHistory"
        case .skillDetail(let skill, _):
            return "skillDetail-\(skill.id)"
        case .compactionDetail:
            return "compaction"
        case .memoryRetainDetail:
            return "memoryRetain"
        case .askUserQuestion:
            return "askUserQuestion"
        case .getConfirmation:
            return "getConfirmation"
        case .subagentDetail:
            return "subagent"
        case .notifyApp(let data):
            return "notifyApp-\(data.toolCallId)"
        case .thinkingDetail:
            return "thinking"
        case .commandToolDetail(let data):
            return "commandTool-\(data.id)"
        case .providerErrorDetail:
            return "providerError"
        case .modelPicker:
            return "modelPicker"
        case .sourceChanges:
            return "sourceChanges"
        }
    }

    // MARK: - Equatable

    static func == (lhs: ChatSheet, rhs: ChatSheet) -> Bool {
        switch (lhs, rhs) {
        case (.settings, .settings):
            return true
        case (.contextAudit, .contextAudit):
            return true
        case (.sessionHistory, .sessionHistory):
            return true
        case (.skillDetail(let skill1, let mode1), .skillDetail(let skill2, let mode2)):
            return skill1.id == skill2.id && mode1 == mode2
        case (.compactionDetail(let data1), .compactionDetail(let data2)):
            return data1 == data2
        case (.memoryRetainDetail(let data1), .memoryRetainDetail(let data2)):
            return data1 == data2
        case (.askUserQuestion, .askUserQuestion):
            return true
        case (.getConfirmation, .getConfirmation):
            return true
        case (.subagentDetail, .subagentDetail):
            return true
        case (.notifyApp(let data1), .notifyApp(let data2)):
            return data1.toolCallId == data2.toolCallId
        case (.thinkingDetail(let content1), .thinkingDetail(let content2)):
            return content1 == content2
        case (.commandToolDetail(let data1), .commandToolDetail(let data2)):
            return data1.id == data2.id
        case (.providerErrorDetail(let data1), .providerErrorDetail(let data2)):
            return data1 == data2
        case (.modelPicker, .modelPicker):
            return true
        case (.sourceChanges, .sourceChanges):
            return true
        default:
            return false
        }
    }
}
