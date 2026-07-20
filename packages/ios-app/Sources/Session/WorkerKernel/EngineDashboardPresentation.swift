import Foundation

/// Human-readable labels for server-owned engine introspection. The server
/// owns membership and counts; this type only owns client copy.
enum EngineDashboardPresentation {
    static func groupTitle(_ group: String) -> String {
        switch group {
        case "host": "Host primitives"
        case "worker_control": "Worker controls"
        case "core_change": "Core changes"
        default: WorkerConsolePresentation.displayLabel(group)
        }
    }

    static func groupDetail(_ group: String, count: Int) -> String {
        let purpose = switch group {
        case "host": "Generic local read, write, process, search, and network closure."
        case "worker_control": "Persistent adaptation, discovery, execution, recovery, and retirement."
        case "core_change": "Isolated proposals with a later conversational approval boundary."
        default: "Fixed engine tools."
        }
        return "\(count) fixed tool\(count == 1 ? "" : "s") · \(purpose)"
    }

    static func selectionReason(_ reason: String?) -> String {
        switch reason {
        case "session_promotion": "Promoted for this session"
        case "relevance": "Relevant to the current task"
        case "default": "Default visible worker"
        case "fixed": "Always-on core"
        default: "Available"
        }
    }
}
