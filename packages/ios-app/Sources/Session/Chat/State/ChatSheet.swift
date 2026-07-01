import Foundation

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
    let recoverable: Bool?
    let origin: String?
    let retryAfterMs: Int?
    let statusCode: Int?
    let errorType: String?
    let model: String?
    let failure: CanonicalFailurePayload?

    init(
        provider: String,
        category: String,
        message: String,
        suggestion: String?,
        retryable: Bool,
        statusCode: Int?,
        errorType: String?,
        model: String?,
        recoverable: Bool? = nil,
        origin: String? = nil,
        retryAfterMs: Int? = nil,
        failure: CanonicalFailurePayload? = nil
    ) {
        self.provider = provider
        self.category = category
        self.message = message
        self.suggestion = suggestion
        self.retryable = retryable
        self.statusCode = statusCode
        self.errorType = errorType
        self.model = model
        self.recoverable = recoverable
        self.origin = origin
        self.retryAfterMs = retryAfterMs
        self.failure = failure
    }
}

struct LocalErrorDetailData: Equatable, Hashable {
    let title: String
    let message: String
    let suggestion: String?
}

struct ContextControlSheetData: Equatable, Hashable {
    let initialActionResourceId: String?

    init(initialActionResourceId: String? = nil) {
        self.initialActionResourceId = initialActionResourceId
    }
}

/// Identifiable enum representing all possible sheets in ChatView.
/// Uses single sheet(item:) modifier pattern per SwiftUI best practices.
/// This avoids Swift compiler type-checking timeout with multiple .sheet() modifiers.
enum ChatSheet: Identifiable, Equatable {
    // Settings & Info
    case settings

    case compactionDetail(CompactionDetailData)

    case thinkingDetail(String)
    case providerErrorDetail(ProviderErrorDetailData)
    case localErrorDetail(LocalErrorDetailData)
    case contextControl(ContextControlSheetData)

    // Capability detail
    case capabilityInvocationDetail(CapabilityInvocationData)


    var id: String {
        switch self {
        case .settings:
            return "settings"
        case .compactionDetail:
            return "compaction"
        case .thinkingDetail:
            return "thinking"
        case .capabilityInvocationDetail(let data):
            return "capability-\(data.id)"
        case .providerErrorDetail:
            return "providerError"
        case .localErrorDetail(let data):
            return "localError-\(data.title)-\(data.message)"
        case .contextControl(let data):
            return "contextControl-\(data.initialActionResourceId ?? "overview")"
        }
    }

    // MARK: - Equatable

    static func == (lhs: ChatSheet, rhs: ChatSheet) -> Bool {
        switch (lhs, rhs) {
        case (.settings, .settings):
            return true
        case (.compactionDetail(let data1), .compactionDetail(let data2)):
            return data1 == data2
        case (.thinkingDetail(let content1), .thinkingDetail(let content2)):
            return content1 == content2
        case (.capabilityInvocationDetail(let data1), .capabilityInvocationDetail(let data2)):
            return data1.id == data2.id
        case (.providerErrorDetail(let data1), .providerErrorDetail(let data2)):
            return data1 == data2
        case (.localErrorDetail(let data1), .localErrorDetail(let data2)):
            return data1 == data2
        case (.contextControl(let data1), .contextControl(let data2)):
            return data1 == data2
        default:
            return false
        }
    }
}
