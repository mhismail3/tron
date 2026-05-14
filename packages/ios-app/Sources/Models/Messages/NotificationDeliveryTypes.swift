import Foundation
import SwiftUI

// MARK: - Notification Delivery Types

/// Status for a `notifications::send` capability delivery.
enum NotificationDeliveryStatus: String, Equatable, Codable {
    case sending
    case sent
    case failed

    var color: Color {
        switch self {
        case .sending: .tronAmber
        case .sent: .tronSuccess
        case .failed: .tronError
        }
    }

    var label: String {
        switch self {
        case .sending: "Sending"
        case .sent: "Sent"
        case .failed: "Failed"
        }
    }

    var iconName: String {
        switch self {
        case .sending: ""
        case .sent: "bell.badge.fill"
        case .failed: "bell.slash.fill"
        }
    }
}

/// Data for rendering a notification capability invocation as a compact chip.
struct NotificationDeliveryData: Equatable, Identifiable {
    /// The capability invocation ID.
    let invocationId: String
    /// Notification title
    let title: String
    /// Notification body
    let body: String
    /// Markdown content for the detail sheet
    let sheetContent: String?
    /// Current status
    var status: NotificationDeliveryStatus
    /// Number of devices notified successfully
    var successCount: Int?
    /// Number of devices that failed
    var failureCount: Int?
    /// Error message (when failed)
    var errorMessage: String?

    /// Identifiable conformance uses invocationId
    var id: String { invocationId }
}
