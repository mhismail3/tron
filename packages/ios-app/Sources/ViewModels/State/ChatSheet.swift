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
    case agentControl

    // Skill details
    case skillDetail(Skill)
    case compactionDetail(CompactionDetailData)
    case memoryRetainDetail(MemoryRetainDetailData)

    // Capability sheets
    case userInteraction
    case engineApproval
    case subagentDetail

    // Notification sheets
    case notifyApp(NotifyAppChipData)
    case subagentResultsList
    case thinkingDetail(String)
    case providerErrorDetail(ProviderErrorDetailData)

    // Capability detail
    case capabilityInvocationDetail(CapabilityInvocationData)


    var id: String {
        switch self {
        case .settings:
            return "settings"
        case .agentControl:
            return "agentControl"
        case .skillDetail(let skill):
            return "skillDetail-\(skill.id)"
        case .compactionDetail:
            return "compaction"
        case .memoryRetainDetail:
            return "memoryRetain"
        case .userInteraction:
            return "userInteraction"
        case .engineApproval:
            return "engineApproval"
        case .subagentDetail:
            return "subagent"
        case .subagentResultsList:
            return "subagentResultsList"
        case .notifyApp(let data):
            return "notifyApp-\(data.invocationId)"
        case .thinkingDetail:
            return "thinking"
        case .capabilityInvocationDetail(let data):
            return "capability-\(data.id)"
        case .providerErrorDetail:
            return "providerError"
        }
    }

    // MARK: - Equatable

    static func == (lhs: ChatSheet, rhs: ChatSheet) -> Bool {
        switch (lhs, rhs) {
        case (.settings, .settings):
            return true
        case (.agentControl, .agentControl):
            return true
        case (.skillDetail(let skill1), .skillDetail(let skill2)):
            return skill1.id == skill2.id
        case (.compactionDetail(let data1), .compactionDetail(let data2)):
            return data1 == data2
        case (.memoryRetainDetail(let data1), .memoryRetainDetail(let data2)):
            return data1 == data2
        case (.userInteraction, .userInteraction):
            return true
        case (.engineApproval, .engineApproval):
            return true
        case (.subagentDetail, .subagentDetail):
            return true
        case (.subagentResultsList, .subagentResultsList):
            return true
        case (.notifyApp(let data1), .notifyApp(let data2)):
            return data1.invocationId == data2.invocationId
        case (.thinkingDetail(let content1), .thinkingDetail(let content2)):
            return content1 == content2
        case (.capabilityInvocationDetail(let data1), .capabilityInvocationDetail(let data2)):
            return data1.id == data2.id
        case (.providerErrorDetail(let data1), .providerErrorDetail(let data2)):
            return data1 == data2
        default:
            return false
        }
    }
}
