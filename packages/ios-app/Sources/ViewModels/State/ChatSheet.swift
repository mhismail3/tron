import Foundation

/// Data for compaction detail sheet
struct CompactionDetailData: Equatable {
    let tokensBefore: Int
    let tokensAfter: Int
    let reason: String
    let summary: String?
}

/// Data for memory detail sheet
struct MemoryDetailData: Equatable {
    let title: String
    let entryType: String
    let sessionId: String
    let eventId: String?
}

/// Data for provider error detail sheet
struct ProviderErrorDetailData: Equatable {
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
    // Browser sheets
    case safari(URL)
    case browser

    // Settings & Info
    case settings
    case contextAudit
    case sessionHistory

    // Skill/Spell details
    case skillDetail(Skill, ChipMode)
    case compactionDetail(CompactionDetailData)
    case memoryDetail(MemoryDetailData)

    // Tool sheets
    case askUserQuestion
    case subagentDetail
    case uiCanvas
    case taskList
    case taskDetail(TaskManagerChipData)

    // Notification sheets
    case notifyApp(NotifyAppChipData)
    case thinkingDetail(String)
    case providerErrorDetail(ProviderErrorDetailData)

    // Command tool detail
    case commandToolDetail(CommandToolChipData)

    // Model picker
    case modelPicker

    var id: String {
        switch self {
        case .safari(let url):
            return "safari-\(url.absoluteString)"
        case .browser:
            return "browser"
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
        case .memoryDetail:
            return "memoryDetail"
        case .askUserQuestion:
            return "askUserQuestion"
        case .subagentDetail:
            return "subagent"
        case .uiCanvas:
            return "uiCanvas"
        case .taskList:
            return "taskList"
        case .taskDetail(let data):
            return "taskDetail-\(data.toolCallId)"
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
        }
    }

    // MARK: - Equatable

    static func == (lhs: ChatSheet, rhs: ChatSheet) -> Bool {
        switch (lhs, rhs) {
        case (.safari(let url1), .safari(let url2)):
            return url1 == url2
        case (.browser, .browser):
            return true
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
        case (.memoryDetail(let data1), .memoryDetail(let data2)):
            return data1 == data2
        case (.askUserQuestion, .askUserQuestion):
            return true
        case (.subagentDetail, .subagentDetail):
            return true
        case (.uiCanvas, .uiCanvas):
            return true
        case (.taskList, .taskList):
            return true
        case (.taskDetail(let data1), .taskDetail(let data2)):
            return data1.toolCallId == data2.toolCallId
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
        default:
            return false
        }
    }
}
