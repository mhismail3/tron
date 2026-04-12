import SwiftUI

// MARK: - Activity Line Kind

/// The type of content in a dashboard activity line.
/// Used by both live streaming buffers and persisted card data.
enum ActivityLineKind: String, Codable, Equatable, CaseIterable, Sendable {
    case text
    case userPrompt
    case toolStart
    case toolEnd
    case subagentSpawn
    case subagentDone
    case subagentFailed
    case thinking
    case error
}

// MARK: - Activity Line Status

/// Status of a tool or subagent activity line.
enum ActivityLineStatus: String, Codable, Equatable, CaseIterable, Sendable {
    case running
    case success
    case error
}

// MARK: - Tool Color

/// Type-safe tool color that bridges between ToolDescriptor string names and SwiftUI colors.
/// Replaces the stringly-typed `iconColorName` → `String.resolvedToolColor` pattern.
enum ToolColor: String, Codable, Equatable, CaseIterable, Sendable {
    case tronSlate
    case tronPink
    case orange
    case tronEmerald
    case purple
    case cyan
    case tronInfo
    case tronAmber
    case tronPurple
    case tronIndigo
    case tronTeal
    case tronSuccess
    case tronError
    case tronTextMuted

    var color: Color {
        switch self {
        case .tronSlate: .tronSlate
        case .tronPink: .tronPink
        case .orange: .orange
        case .tronEmerald: .tronEmerald
        case .purple: .purple
        case .cyan: .cyan
        case .tronInfo: .tronInfo
        case .tronAmber: .tronAmber
        case .tronPurple: .tronPurple
        case .tronIndigo: .tronIndigo
        case .tronTeal: .tronTeal
        case .tronSuccess: .tronSuccess
        case .tronError: .tronError
        case .tronTextMuted: .tronTextMuted
        }
    }

    /// Parse from a ToolDescriptor `iconColorName` string. Falls back to `.tronTextMuted`.
    init(fromDescriptorName name: String) {
        self = ToolColor(rawValue: name) ?? .tronTextMuted
    }
}

// MARK: - Dashboard Constants

/// Centralized constants for dashboard card display.
enum DashboardConstants {
    static let maxUserPromptLength = 100
    static let maxAssistantTextLength = 200
    static let maxSubagentTextLength = 50
    static let maxErrorTextLength = 80
    static let maxActivityLines = 5
    static let maxStreamBufferLines = 8
    static let batchIntervalNanos: UInt64 = 16_000_000 // ~60fps
}

// MARK: - Activity Line

/// A single line in a dashboard session card's mini-chat view.
/// Unified type used by both live streaming buffers and persisted card data.
///
/// `id` is excluded from Codable — generated fresh on decode for SwiftUI identity.
/// `toolCallId` is transient (live streaming only) and excluded from Codable.
struct ActivityLine: Identifiable, Codable, Sendable {
    let id: UUID
    let kind: ActivityLineKind
    var text: String
    var icon: String?
    var iconColor: ToolColor?
    var toolName: String?
    var displayName: String?
    var summary: String?
    var duration: String?
    var status: ActivityLineStatus?

    /// Transient: only used during live streaming for tool start/end matching.
    /// Not persisted or encoded.
    var toolCallId: String?

    // MARK: - Memberwise Init

    init(
        kind: ActivityLineKind,
        text: String,
        icon: String? = nil,
        iconColor: ToolColor? = nil,
        toolName: String? = nil,
        displayName: String? = nil,
        summary: String? = nil,
        duration: String? = nil,
        status: ActivityLineStatus? = nil,
        toolCallId: String? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.icon = icon
        self.iconColor = iconColor
        self.toolName = toolName
        self.displayName = displayName
        self.summary = summary
        self.duration = duration
        self.status = status
        self.toolCallId = toolCallId
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case kind, text, icon, iconColor, toolName, displayName, summary, duration, status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.kind = try c.decode(ActivityLineKind.self, forKey: .kind)
        self.text = try c.decode(String.self, forKey: .text)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.iconColor = try c.decodeIfPresent(ToolColor.self, forKey: .iconColor)
        self.toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.duration = try c.decodeIfPresent(String.self, forKey: .duration)
        self.status = try c.decodeIfPresent(ActivityLineStatus.self, forKey: .status)
        self.toolCallId = nil
    }
}

// MARK: - Equatable (exclude id and toolCallId)

extension ActivityLine: Equatable {
    static func == (lhs: ActivityLine, rhs: ActivityLine) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.text == rhs.text &&
        lhs.icon == rhs.icon &&
        lhs.iconColor == rhs.iconColor &&
        lhs.toolName == rhs.toolName &&
        lhs.displayName == rhs.displayName &&
        lhs.summary == rhs.summary &&
        lhs.duration == rhs.duration &&
        lhs.status == rhs.status
    }
}
