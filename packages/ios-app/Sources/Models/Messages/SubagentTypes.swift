import Foundation
import SwiftUI

// MARK: - Subagent Types

/// Status for a spawned subagent
enum SubagentStatus: String, Codable, Equatable {
    case running
    case completed
    case failed

    var color: Color {
        switch self {
        case .running: .tronAmber
        case .completed: .tronSuccess
        case .failed: .tronError
        }
    }

    var label: String {
        switch self {
        case .running: "Agent running"
        case .completed: "Agent completed"
        case .failed: "Agent failed"
        }
    }

    var iconName: String {
        switch self {
        case .running: ""
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}

/// Tracks how completed subagent results are delivered to the parent agent.
/// Used for non-blocking subagents only (blocking subagents deliver via capability result).
///
/// When a non-blocking subagent completes during an active turn, the backend
/// delivers results via system prompt injection — no iOS-side action needed.
/// This status only tracks the notification flow for results arriving while idle.
enum SubagentResultDeliveryStatus: String, Codable, Equatable {
    /// Blocking subagent or results delivered by backend — no user action needed
    case notApplicable
    /// Completed while parent idle, notification shown, awaiting user action
    case pending
    /// Results delivered to agent
    case sent
    /// User dismissed without sending
    case dismissed
}

/// Categorizes the origin of a subagent for UI-level decisions
/// (e.g., whether it suppresses the breathing line or shows a chip).
///
/// Decoding is strict: the server is the source of truth and every
/// `subagent_spawned` / `subagent_completed` / `subagent_failed` event
/// carries a non-empty `spawnType` string from `SpawnType::as_str` on
/// the Rust side. A missing or unrecognised value on the wire indicates
/// a schema drift (iOS/server out of sync) and MUST be surfaced as a
/// decode failure, not silently coerced into `.capabilityAgent`.
enum SubagentSpawnType: String, Codable, Equatable {
    case capabilityAgent
    case subsession
    case hook

    /// Failable init from a raw wire value. Returns nil for unknown
    /// variants and for `nil` — callers decide whether to drop the
    /// record, log a warning, or fall back to a safe default.
    init?(from rawValue: String?) {
        switch rawValue {
        case "capabilityAgent": self = .capabilityAgent
        case "subsession": self = .subsession
        case "hook": self = .hook
        default: return nil
        }
    }
}

struct SubagentTaskProfilePresentation: Codable, Equatable, Sendable {
    let id: String
    let label: String
}

struct SubagentModelRoutingPresentation: Codable, Equatable, Sendable {
    let preset: String?
    let presetLabel: String?
    let selectionStatus: String
    let localOptIn: Bool
    let selectedModel: String?
    let selectedModelLabel: String?
    let modelClass: String?
    let fallbackUsed: Bool
    let fallbackLabel: String?
    let fallbackReason: String?
    let policyProfile: String?

    var chipModelLabel: String? {
        selectedModelLabel ?? selectedModel ?? presetLabel ?? preset
    }
}

/// Data for tracking a spawned subagent (rendered as a chip in chat)
struct SubagentInvocationData: Equatable {
    /// The capability invocation ID for the subagent request.
    let invocationId: String
    /// Session ID of the spawned subagent
    let subagentSessionId: String
    /// Whether the server has emitted the child session id needed for
    /// history/detail loading.
    var hasSubagentSession: Bool {
        subagentSessionId.hasPrefix("sess_")
    }
    /// The task assigned to the subagent
    let task: String
    /// Model used by the subagent
    var model: String?
    /// Server-owned task profile presentation
    var taskProfile: SubagentTaskProfilePresentation? = nil
    /// Server-owned model route presentation
    var modelRouting: SubagentModelRoutingPresentation? = nil
    /// Current status
    var status: SubagentStatus
    /// Current turn number (while running)
    var currentTurn: Int
    /// Result summary (when completed)
    var resultSummary: String?
    /// Full output (when completed)
    var fullOutput: String?
    /// Duration in milliseconds
    var duration: Int?
    /// Error message (when failed)
    var error: String?
    /// Token usage (when completed)
    var tokenUsage: TokenUsage?
    /// Whether this subagent was spawned in blocking mode (parent waits for result via capability result)
    var blocking: Bool = false
    /// Origin of the subagent (capability, hook, subsession) — controls UI behavior
    var spawnType: SubagentSpawnType = .capabilityAgent
    /// Tracks whether results need user action (for non-blocking subagents that complete while parent idle)
    var resultDeliveryStatus: SubagentResultDeliveryStatus = .notApplicable

    /// Formatted duration for display
    var formattedDuration: String? {
        guard let ms = duration else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    /// Short task preview for chip display
    var taskPreview: String {
        task.truncated(to: 43)
    }

    var routePreview: String? {
        let profile = taskProfile?.label
        let modelLabel = modelRouting?.chipModelLabel ?? model
        switch (profile, modelLabel) {
        case (.some(let profile), .some(let modelLabel)):
            return "\(profile) / \(modelLabel)"
        case (.some(let profile), .none):
            return profile
        case (.none, .some(let modelLabel)):
            return modelLabel
        case (.none, .none):
            return nil
        }
    }

    var resultPreview: String? {
        guard status == .completed || status == .failed else { return nil }
        if let resultSummary, !resultSummary.isEmpty {
            return resultSummary.truncated(to: 36)
        }
        if let error, !error.isEmpty {
            return error.truncated(to: 36)
        }
        return nil
    }
}
