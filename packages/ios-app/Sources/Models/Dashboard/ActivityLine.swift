import SwiftUI

// MARK: - Activity Line Kind

/// The type of content in a dashboard activity line.
/// Used by both live streaming buffers and persisted card data.
enum ActivityLineKind: String, Codable, Equatable, CaseIterable, Sendable {
    case text
    case userPrompt
    case capabilityInvocationStarted
    case capabilityInvocationCompleted
    case subagentSpawn
    case subagentDone
    case subagentFailed
    case thinking
    case error
}

// MARK: - Activity Line Status

/// Status of a capability or subagent activity line.
enum ActivityLineStatus: String, Codable, Equatable, CaseIterable, Sendable {
    case running
    case success
    case error
}

// MARK: - Capability Risk Color

/// Type-safe capability color that bridges between capability presentation hint names and SwiftUI colors.
/// Replaces the stringly-typed `presentationColorName` → `String.resolvedCapabilityColor` pattern.
enum CapabilityColor: String, Codable, Equatable, CaseIterable, Sendable {
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

    /// Parse from a capability presentation hint color string. Falls back to `.tronTextMuted`.
    init(fromDescriptorName name: String) {
        self = CapabilityColor(rawValue: name) ?? .tronTextMuted
    }

    static func fromCapability(_ identity: CapabilityIdentity) -> CapabilityColor {
        switch identity.riskLevel?.lowercased() {
        case "critical", "high":
            return .tronError
        case "medium":
            return .tronAmber
        default:
            return .tronInfo
        }
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
/// `invocationId` is transient (live streaming only) and excluded from Codable.
struct ActivityLine: Identifiable, Codable, Sendable {
    let id: UUID
    let kind: ActivityLineKind
    var text: String
    var icon: String?
    var iconColor: CapabilityColor?
    var modelPrimitiveName: String?
    var displayName: String?
    var summary: String?
    var duration: String?
    var status: ActivityLineStatus?
    var capabilityIdentity: CapabilityIdentity?

    /// Transient: only used during live streaming for capability start/end matching.
    /// Not persisted or encoded.
    var invocationId: String?

    // MARK: - Memberwise Init

    init(
        kind: ActivityLineKind,
        text: String,
        icon: String? = nil,
        iconColor: CapabilityColor? = nil,
        modelPrimitiveName: String? = nil,
        displayName: String? = nil,
        summary: String? = nil,
        duration: String? = nil,
        status: ActivityLineStatus? = nil,
        invocationId: String? = nil,
        capabilityIdentity: CapabilityIdentity? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.icon = icon
        self.iconColor = iconColor
        self.modelPrimitiveName = modelPrimitiveName
        self.displayName = displayName
        self.summary = summary
        self.duration = duration
        self.status = status
        self.invocationId = invocationId
        self.capabilityIdentity = capabilityIdentity
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case kind, text, icon, iconColor, modelPrimitiveName, displayName, summary, duration, status, capabilityIdentity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.kind = try c.decode(ActivityLineKind.self, forKey: .kind)
        self.text = try c.decode(String.self, forKey: .text)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.iconColor = try c.decodeIfPresent(CapabilityColor.self, forKey: .iconColor)
        self.modelPrimitiveName = try c.decodeIfPresent(String.self, forKey: .modelPrimitiveName)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.duration = try c.decodeIfPresent(String.self, forKey: .duration)
        self.status = try c.decodeIfPresent(ActivityLineStatus.self, forKey: .status)
        self.capabilityIdentity = try c.decodeIfPresent(CapabilityIdentity.self, forKey: .capabilityIdentity)
        self.invocationId = nil
    }
}

// MARK: - Equatable (exclude id and invocationId)

extension ActivityLine: Equatable {
    static func == (lhs: ActivityLine, rhs: ActivityLine) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.text == rhs.text &&
        lhs.icon == rhs.icon &&
        lhs.iconColor == rhs.iconColor &&
        lhs.modelPrimitiveName == rhs.modelPrimitiveName &&
        lhs.displayName == rhs.displayName &&
        lhs.summary == rhs.summary &&
        lhs.duration == rhs.duration &&
        lhs.status == rhs.status &&
        lhs.capabilityIdentity == rhs.capabilityIdentity
    }
}
