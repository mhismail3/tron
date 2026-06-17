import Foundation

extension ChatViewModel {
    enum ErrorSeverity {
        case fatal
        case warning
        case info
    }

    func handleError(_ message: String, severity: ErrorSeverity = .fatal, category: LogCategory = .session) {
        switch severity {
        case .fatal:
            logger.error(message, category: category)
            appendLocalError(dedupKey: "chat.error.generic", title: "Chat error", message: message)
        case .warning:
            logger.warning(message, category: category)
        case .info:
            logger.info(message, category: category)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func appendLocalError(
        dedupKey: String,
        title: String,
        message: String,
        suggestion: String? = nil
    ) {
        let notification = LocalChatNotification.error(
            dedupKey: dedupKey,
            title: title,
            message: message,
            suggestion: suggestion
        )

        if let existingId = localNotificationIdsByDedupKey[dedupKey],
           let index = messages.firstIndex(where: { $0.id == existingId }) {
            messages[index] = .localNotification(notification)
            localNotificationIdsByDedupKey[dedupKey] = notification.id
            return
        }

        localNotificationIdsByDedupKey[dedupKey] = notification.id
        appendToMessages(.localNotification(notification))
    }

    func clearLocalNotifications() {
        guard !localNotificationIdsByDedupKey.isEmpty else { return }
        let ids = Set(localNotificationIdsByDedupKey.values)
        removeFromMessages { ids.contains($0.id) }
        localNotificationIdsByDedupKey.removeAll()
    }
}
