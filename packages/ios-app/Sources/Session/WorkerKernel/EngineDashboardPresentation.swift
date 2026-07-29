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
        case "worker_inbox": "View Worker Results"
        case "worker_runs": "View Worker Runs"
        case "worker_webhook_rotate": "Rotate Webhook Token"
        case "worker_stop_all": "Stop All Workers"
        default: WorkerConsolePresentation.displayLabel(modelName)
        }
    }

    static func groupTitle(_ group: String) -> String {
        switch group {
        case "host": "Host primitives"
        case "session": "Session"
        case "worker_interaction": "Worker interaction"
        case "worker_administration": "Worker administration"
        default: WorkerConsolePresentation.displayLabel(group)
        }
    }

    static func groupDetail(_ group: String, count: Int) -> String {
        let purpose = switch group {
        case "host": "Generic local read, write, process, search, and network closure."
        case "session": "Request-gated mutation of the current conversation."
        case "worker_interaction": "Stable discovery and control of work already in progress."
        case "worker_administration": "Exact specialist or authenticated-dashboard worker lifecycle operations."
        default: "Fixed engine tools."
        }
        return "\(count) fixed tool\(count == 1 ? "" : "s") · \(purpose)"
    }

}
