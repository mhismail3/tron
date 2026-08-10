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

/// Immutable source-aware snapshot for the reasoning detail sheet.
struct ThinkingDetailData: Equatable {
    let content: String
    let kind: ThinkingDisplayKind
}

/// One immutable, local image in a chat attachment preview.
struct ChatImagePreviewItem: Identifiable, Equatable {
    let id: String
    let data: Data
    let accessibilityLabel: String

    init(attachment: Attachment) {
        id = "attachment-\(attachment.id.uuidString)"
        data = attachment.data
        accessibilityLabel = "Preview \(attachment.displayName)"
    }

    init(image: ImageContent) {
        id = "image-\(image.id.uuidString)"
        data = image.data
        accessibilityLabel = "Preview photo"
    }

    static func == (lhs: ChatImagePreviewItem, rhs: ChatImagePreviewItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Immutable, local gallery payload for chat image previews.
///
/// A gallery contains only the images from the originating attachment group,
/// preserving their visible order and the item the user selected. Image bytes
/// are retained by the already-loaded message and never fetched again when the
/// preview opens.
struct ChatImagePreviewData: Equatable {
    let id: String
    let items: [ChatImagePreviewItem]
    let initialItemID: String
    let title: String

    init(attachments: [Attachment], selected: Attachment) {
        let selectedItem = ChatImagePreviewItem(attachment: selected)
        let groupedItems = attachments
            .filter(\.isImage)
            .map(ChatImagePreviewItem.init(attachment:))
        items = groupedItems.contains(selectedItem) ? groupedItems : [selectedItem]
        initialItemID = selectedItem.id
        id = selectedItem.id
        title = "Photo"
    }

    init(images: [ImageContent], selected: ImageContent) {
        let selectedItem = ChatImagePreviewItem(image: selected)
        let groupedItems = images.map(ChatImagePreviewItem.init(image:))
        items = groupedItems.contains(selectedItem) ? groupedItems : [selectedItem]
        initialItemID = selectedItem.id
        id = selectedItem.id
        title = "Photo"
    }

    init(attachment: Attachment) {
        self.init(attachments: [attachment], selected: attachment)
    }

    init(image: ImageContent) {
        self.init(images: [image], selected: image)
    }

    var initialIndex: Int {
        items.firstIndex { $0.id == initialItemID } ?? 0
    }

    static func == (lhs: ChatImagePreviewData, rhs: ChatImagePreviewData) -> Bool {
        lhs.id == rhs.id
    }
}

/// Identifiable enum representing all possible sheets in ChatView.
/// Uses single sheet(item:) modifier pattern per SwiftUI best practices.
/// This avoids Swift compiler type-checking timeout with multiple .sheet() modifiers.
enum ChatSheet: Identifiable, Equatable {
    // Settings & Info
    case settings
    case sessionContext

    case compactionDetail(CompactionDetailData)

    case thinkingDetail(ThinkingDetailData)
    case providerErrorDetail(ProviderErrorDetailData)
    case localErrorDetail(LocalErrorDetailData)

    // Tool detail
    case toolInvocationDetail(ToolInvocationData)
    case toolInvocationGroupDetail(ToolInvocationGroupData)
    case userInput(UserInputRequest)
    case imagePreview(ChatImagePreviewData)


    var id: String {
        switch self {
        case .settings:
            return "settings"
        case .sessionContext:
            return "sessionContext"
        case .compactionDetail:
            return "compaction"
        case .thinkingDetail:
            return "thinking"
        case .toolInvocationDetail(let data):
            return "tool-\(data.id)"
        case .toolInvocationGroupDetail(let data):
            return "tool-group-\(data.id)"
        case .userInput(let request):
            return "user-input-\(request.invocationId)"
        case .imagePreview(let preview):
            return "image-preview-\(preview.id)"
        case .providerErrorDetail:
            return "providerError"
        case .localErrorDetail(let data):
            return "localError-\(data.title)-\(data.message)"
        }
    }

    // MARK: - Equatable

    static func == (lhs: ChatSheet, rhs: ChatSheet) -> Bool {
        switch (lhs, rhs) {
        case (.settings, .settings):
            return true
        case (.sessionContext, .sessionContext):
            return true
        case (.compactionDetail(let data1), .compactionDetail(let data2)):
            return data1 == data2
        case (.thinkingDetail(let data1), .thinkingDetail(let data2)):
            return data1 == data2
        case (.toolInvocationDetail(let data1), .toolInvocationDetail(let data2)):
            return data1.id == data2.id
        case (.toolInvocationGroupDetail(let data1), .toolInvocationGroupDetail(let data2)):
            return data1.id == data2.id
        case (.userInput(let lhs), .userInput(let rhs)):
            return lhs.invocationId == rhs.invocationId
        case (.imagePreview(let lhs), .imagePreview(let rhs)):
            return lhs == rhs
        case (.providerErrorDetail(let data1), .providerErrorDetail(let data2)):
            return data1 == data2
        case (.localErrorDetail(let data1), .localErrorDetail(let data2)):
            return data1 == data2
        default:
            return false
        }
    }

    /// Source-compatible constructor for raw provider thinking.
    static func thinkingDetail(_ content: String) -> ChatSheet {
        .thinkingDetail(ThinkingDetailData(content: content, kind: .thinking))
    }
}
