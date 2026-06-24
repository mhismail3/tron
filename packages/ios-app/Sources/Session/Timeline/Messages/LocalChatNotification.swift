import Foundation

struct LocalChatNotification: Equatable, Identifiable {
    enum Severity: Equatable {
        case info
        case warning
        case error
    }

    enum Detail: Equatable {
        case error(title: String, message: String, suggestion: String?)
    }

    let id: UUID
    let dedupKey: String
    let severity: Severity
    let title: String
    let message: String?
    let detail: Detail?

    init(
        id: UUID = UUID(),
        dedupKey: String,
        severity: Severity,
        title: String,
        message: String? = nil,
        detail: Detail? = nil
    ) {
        self.id = id
        self.dedupKey = dedupKey
        self.severity = severity
        self.title = title
        self.message = message?.nilIfEmpty
        self.detail = detail
    }

    static func error(
        dedupKey: String,
        title: String,
        message: String,
        suggestion: String? = nil
    ) -> LocalChatNotification {
        LocalChatNotification(
            dedupKey: dedupKey,
            severity: .error,
            title: title,
            message: message,
            detail: .error(title: title, message: message, suggestion: suggestion)
        )
    }

    var textContent: String {
        [title, message].compactMap(\.self).joined(separator: ": ")
    }
}
