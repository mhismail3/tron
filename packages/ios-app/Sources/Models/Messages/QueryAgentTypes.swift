import SwiftUI

// MARK: - QueryAgent Types

enum QueryType: String, Equatable {
    case status
    case events
    case logs
    case output
    case unknown

    var displayName: String {
        switch self {
        case .status: "Status"
        case .events: "Events"
        case .logs: "Logs"
        case .output: "Output"
        case .unknown: "Query"
        }
    }

    var icon: String {
        switch self {
        case .status: "gauge.with.dots.needle.33percent"
        case .events: "list.bullet.rectangle"
        case .logs: "text.document"
        case .output: "text.bubble"
        case .unknown: "magnifyingglass"
        }
    }
}

enum QueryAgentStatus: Equatable {
    case querying
    case success
    case error
}

struct QueryAgentChipData: Equatable, Identifiable {
    let toolCallId: String
    let sessionId: String
    let queryType: QueryType
    var status: QueryAgentStatus
    var durationMs: Int?
    var resultPreview: String?
    var fullResult: String?
    var errorMessage: String?

    var id: String { toolCallId }

    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}
