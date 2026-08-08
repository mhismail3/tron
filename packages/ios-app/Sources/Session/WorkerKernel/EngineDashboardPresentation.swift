import Foundation

struct EnginePrimitiveGroup: Equatable, Identifiable {
    let id: String
    let tools: [EngineSurfaceToolDTO]
}

/// Human-readable labels for server-owned engine introspection. The server
/// owns membership and counts; this type only owns client copy.
enum EngineDashboardPresentation {
    private static let preferredGroupOrder = [
        "host",
        "user_interaction",
        "session",
        "worker_interaction",
        "worker_administration",
    ]

    /// Preserve server tool order inside each group, retain the product's
    /// familiar group order, and append every future server-owned group rather
    /// than silently dropping inventory the client does not yet recognize.
    static func primitiveGroups(_ tools: [EngineSurfaceToolDTO]) -> [EnginePrimitiveGroup] {
        let grouped = Dictionary(grouping: tools) { tool in
            guard let group = tool.primitiveGroup, !group.isEmpty else { return "other" }
            return group
        }
        let known = preferredGroupOrder.filter { grouped[$0] != nil }
        let future = grouped.keys
            .filter { !preferredGroupOrder.contains($0) }
            .sorted()
        return (known + future).compactMap { group in
            grouped[group].map { EnginePrimitiveGroup(id: group, tools: $0) }
        }
    }

    static func toolTitle(_ modelName: String) -> String {
        switch modelName {
        case "filesystem_read": "Read File"
        case "filesystem_list": "List Directory"
        case "filesystem_search_text": "Search Files"
        case "filesystem_write": "Write File"
        case "filesystem_edit": "Edit File"
        case "process_run": "Run Process"
        case "web_fetch": "Fetch Web Page"
        case "request_user_input": "Ask User"
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
        case "user_interaction": "User interaction"
        case "session": "Session metadata"
        case "worker_interaction": "Worker interaction"
        case "worker_administration": "Worker administration"
        case "other": "Other primitives"
        default: "\(WorkerConsolePresentation.displayLabel(group)) primitives"
        }
    }

    static func groupDetail(_ group: String, count: Int) -> String {
        let purpose = switch group {
        case "host": "Generic local read, write, process, search, and network closure."
        case "user_interaction": "Foreground questions with a durable answer handoff."
        case "session": "Request-gated mutation of canonical conversation metadata."
        case "worker_interaction": "Stable discovery and control of work already in progress."
        case "worker_administration": "Exact specialist or authenticated-dashboard worker lifecycle operations."
        default: "Fixed engine primitives reported by the server."
        }
        return "\(count) fixed primitive\(count == 1 ? "" : "s") · \(purpose)"
    }

    static func toolAvailability(_ tool: EngineSurfaceToolDTO) -> String {
        switch (tool.audience, tool.exposed) {
        case ("ordinary", true): "Ordinary · Available"
        case ("conditional", true): "Conditional · Available for this request"
        case ("conditional", false): "Conditional · Available only when requested"
        case ("specialist", true): "Specialist · Available"
        case ("specialist", false): "Specialist · Not projected"
        case (_, true): "Available"
        case (_, false): "Not projected"
        }
    }

}
