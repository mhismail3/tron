import SwiftUI

/// Provides consistent event icons and colors across all session history views.
enum EventIconProvider {

    // MARK: - Icon Names

    /// System image name for an event type
    static func iconName(for eventType: SessionEventType, payload: [String: AnyCodable]? = nil) -> String {
        switch eventType {
        case .sessionStart:
            return "play.circle.fill"
        case .sessionEnd:
            return "stop.circle.fill"
        case .sessionFork, .sessionBranch:
            return "arrow.triangle.branch"
        case .messageUser:
            return "person.fill"
        case .messageAssistant:
            return "cpu"
        case .messageSystem:
            return "gearshape.fill"
        case .messageDeleted:
            return "trash.fill"
        case .toolCall:
            return "wrench.and.screwdriver"
        case .toolResult:
            if isError(payload) {
                return "xmark.circle.fill"
            }
            return "checkmark.circle.fill"
        case .rulesLoaded:
            return "doc.text.fill"
        case .contextCleared:
            return "clear.fill"
        case .skillAdded, .skillRemoved:
            return "sparkles"
        case .compactBoundary, .compactSummary:
            return "arrow.down.right.and.arrow.up.left"
        case .memoryLedger:
            return "brain.fill"
        case .configModelSwitch:
            return "arrow.triangle.2.circlepath"
        case .configPromptUpdate, .configReasoningLevel:
            return "slider.horizontal.3"
        case .fileRead, .fileWrite, .fileEdit:
            return "doc.fill"
        case .errorAgent, .errorTool:
            return "exclamationmark.triangle.fill"
        case .errorProvider:
            return "arrow.clockwise.circle"
        case .notificationInterrupted:
            return "pause.circle.fill"
        case .metadataUpdate, .metadataTag:
            return "tag.fill"
        case .streamTurnStart:
            return "arrow.right.circle"
        case .streamTurnEnd:
            return "arrow.down.circle"
        default:
            return "circle.fill"
        }
    }

    // MARK: - Colors

    /// Color for an event type
    static func color(for eventType: SessionEventType, payload: [String: AnyCodable]? = nil) -> Color {
        switch eventType {
        case .sessionStart:
            return .tronSuccess
        case .sessionEnd:
            return .tronTextMuted
        case .sessionFork, .sessionBranch:
            return .tronPurple
        case .messageUser:
            return .tronBlue
        case .messageAssistant:
            return .tronSuccess
        case .messageSystem:
            return .tronTextMuted
        case .messageDeleted:
            return .tronError
        case .toolCall:
            return .tronCyan
        case .toolResult:
            if isError(payload) {
                return .tronError
            }
            return .tronSuccess
        case .rulesLoaded:
            return .tronPurple
        case .contextCleared:
            return .tronCyan
        case .skillAdded:
            return .tronSuccess
        case .skillRemoved:
            return .tronWarning
        case .compactBoundary, .compactSummary:
            return .tronCyan
        case .memoryLedger:
            return .purple
        case .configModelSwitch:
            return .tronPurple
        case .configPromptUpdate, .configReasoningLevel:
            return .tronPurple
        case .fileRead, .fileWrite, .fileEdit:
            return .tronCyan
        case .errorAgent, .errorTool:
            return .tronError
        case .errorProvider:
            return .tronError
        case .notificationInterrupted:
            return .tronWarning
        case .metadataUpdate, .metadataTag:
            return .tronTextMuted
        case .streamTurnStart, .streamTurnEnd:
            return .tronBlue
        default:
            return .tronTextMuted
        }
    }

    // MARK: - View Builders

    /// Icon view for an event
    @ViewBuilder
    static func icon(for event: SessionEvent) -> some View {
        Image(systemName: iconName(for: event.eventType, payload: event.payload))
    }

    /// Icon view for an event type
    @ViewBuilder
    static func icon(for eventType: SessionEventType, payload: [String: AnyCodable]? = nil) -> some View {
        Image(systemName: iconName(for: eventType, payload: payload))
    }

    // MARK: - Helpers

    /// Check if payload indicates an error
    private static func isError(_ payload: [String: AnyCodable]?) -> Bool {
        guard let payload = payload else { return false }
        return (payload["isError"]?.value as? Bool) == true
    }
}
