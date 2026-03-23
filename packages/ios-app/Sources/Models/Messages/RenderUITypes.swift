import Foundation
import SwiftUI

// MARK: - RenderUI Types

/// Status for a RenderUI canvas
enum RenderUIStatus: String, Equatable {
    case rendering
    case ready
    case error

    var color: Color {
        switch self {
        case .rendering: .tronAmber
        case .ready: .tronSuccess
        case .error: .tronError
        }
    }

    var label: String {
        switch self {
        case .rendering: "Rendering"
        case .ready: "Ready"
        case .error: "Failed"
        }
    }

    var iconName: String {
        switch self {
        case .rendering: ""
        case .ready: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }
}

/// Data for tracking a RenderUI tool call (rendered as a chip in chat)
struct RenderUIChipData: Equatable {
    var toolCallId: String
    let canvasId: String
    let url: String
    let title: String?
    var status: RenderUIStatus
    var errorMessage: String?

    var displayTitle: String {
        title ?? "Preview"
    }

    var isTappable: Bool {
        status == .rendering || status == .ready
    }
}
