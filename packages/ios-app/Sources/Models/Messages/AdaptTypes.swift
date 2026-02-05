import Foundation

// MARK: - Adapt Types

/// Status for an Adapt (self-deployment) tool call
enum AdaptStatus: String, Equatable, Codable {
    case running
    case success
    case failed
}

/// The deployment action being performed
enum AdaptAction: String, Equatable, Codable {
    case deploy
    case status
    case rollback
}

/// Data for rendering an Adapt tool call as a compact chip
struct AdaptChipData: Equatable, Identifiable {
    /// The tool call ID
    let toolCallId: String
    /// The deployment action (deploy, status, rollback)
    let action: AdaptAction
    /// Current status
    var status: AdaptStatus
    /// The full result text for the detail sheet
    var resultContent: String?
    /// Whether the result indicates an error
    var isError: Bool

    /// Identifiable conformance uses toolCallId
    var id: String { toolCallId }
}
