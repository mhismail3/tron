import Foundation

/// Human-readable labels for server-owned engine introspection. The server
/// owns membership and counts; this type only owns client copy.
enum EngineDashboardPresentation {
    static func toolTitle(_ modelName: String) -> String {
        switch modelName {
        case "filesystem_read": "Read File"
        case "filesystem_list": "List Directory"
        case "filesystem_search_text": "Search Files"
        case "filesystem_write": "Write File"
        case "filesystem_edit": "Edit File"
        case "process_run": "Run Process"
        case "web_fetch": "Fetch Web Page"
        case "session_set_title": "Set Session Title"
        case "worker_upsert": "Create or Update Worker"
        case "worker_discover": "Discover Workers"
        case "worker_list": "List Workers"
        case "worker_inspect": "Inspect Worker"
        case "worker_invoke": "Run Worker"
        case "worker_await": "Wait for Worker"
        case "worker_cancel": "Cancel Worker Run"
        case "worker_enable": "Enable Worker"
        case "worker_disable": "Disable Worker"
        case "worker_stop": "Stop Worker"
        case "worker_rollback": "Roll Back Worker"
        case "worker_retire": "Retire Worker"
        case "worker_purge": "Delete Worker"
        case "worker_inbox": "View Worker Inbox"
        case "worker_runs": "View Worker Runs"
        case "worker_webhook_rotate": "Rotate Webhook Token"
        case "worker_stop_all": "Stop All Workers"
        case "core_proposal_create": "Create Core Proposal"
        case "core_proposal_list": "List Core Proposals"
        case "core_proposal_inspect": "Inspect Core Proposal"
        case "core_proposal_apply": "Apply Core Proposal"
        default: WorkerConsolePresentation.displayLabel(modelName)
        }
    }

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

    static func routingEvidence(_ worker: AvailableWorkerToolDTO) -> String {
        let reason = selectionReason(worker.selectionReason)
        let runs = "\(worker.completedRuns) completed run\(worker.completedRuns == 1 ? "" : "s")"
        return "\(reason) · score \(worker.relevanceScore) · \(runs)"
    }
}
