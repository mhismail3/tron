import SwiftUI

// MARK: - WaitForAgents Types

enum WaitMode: String, Equatable {
    case all
    case any
}

enum WaitForAgentsStatus: Equatable {
    case waiting
    case completed
    case timedOut
    case error
}

struct WaitForAgentsChipData: Equatable, Identifiable {
    let toolCallId: String
    let sessionIds: [String]
    let mode: WaitMode
    var status: WaitForAgentsStatus
    var completedCount: Int
    var durationMs: Int?
    var resultPreview: String?
    var fullResult: String?
    var errorMessage: String?

    var id: String { toolCallId }

    var agentCount: Int { sessionIds.count }

    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}
