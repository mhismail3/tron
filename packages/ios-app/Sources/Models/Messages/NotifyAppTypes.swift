import Foundation

// MARK: - NotifyApp Types

/// Status for a NotifyApp push notification
enum NotifyAppStatus: String, Equatable, Codable {
    case sending
    case sent
    case failed
}

/// Data for rendering a NotifyApp tool call as a compact chip
struct NotifyAppChipData: Equatable, Identifiable {
    /// The tool call ID from NotifyApp
    let toolCallId: String
    /// Notification title
    let title: String
    /// Notification body
    let body: String
    /// Markdown content for the detail sheet
    let sheetContent: String?
    /// Current status
    var status: NotifyAppStatus
    /// Number of devices notified successfully
    var successCount: Int?
    /// Number of devices that failed
    var failureCount: Int?
    /// Error message (when failed)
    var errorMessage: String?

    /// Identifiable conformance uses toolCallId
    var id: String { toolCallId }
}
