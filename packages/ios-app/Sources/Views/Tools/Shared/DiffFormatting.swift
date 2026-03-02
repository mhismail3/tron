import SwiftUI

/// Diff line type classifications for unified diff rendering.
enum EditDiffLineType {
    case context
    case addition
    case deletion
    case separator
}

/// Shared diff line styling helpers.
/// Replaces duplicate formatting logic in EditToolDetailSheet and SourceChangesSheet.
enum DiffFormatting {

    static func marker(for type: EditDiffLineType) -> String {
        switch type {
        case .addition: return "+"
        case .deletion: return "\u{2212}"
        case .context, .separator: return ""
        }
    }

    static func markerColor(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        case .context, .separator: return .clear
        }
    }

    static func lineNumColor(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        case .context, .separator: return .tronTextMuted
        }
    }

    static func lineBackground(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return Color.tronSuccess.opacity(0.08)
        case .deletion: return Color.tronError.opacity(0.08)
        case .context, .separator: return .clear
        }
    }
}
