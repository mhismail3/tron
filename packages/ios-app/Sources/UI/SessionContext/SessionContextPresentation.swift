import SwiftUI

enum SessionContextPressure: Equatable {
    case normal
    case elevated
    case critical

    var color: Color {
        switch self {
        case .normal: .tronEmerald
        case .elevated: .tronAmber
        case .critical: .tronError
        }
    }
}

/// Pure presentation and action policy for the Session Context surface.
enum SessionContextPresentation {
    static let sheetTitle = "Manage Session"
    static let terminalActionTitle = "Terminal"

    /// Completed cards separate clearly from the next section, while each
    /// heading remains visually attached to the content it introduces.
    static let sectionSpacing: CGFloat = 20
    static let headerToContentSpacing: CGFloat = 4
    static let headerToSubheaderSpacing: CGFloat = 0

    static func boundedPercentage(_ percentage: Int) -> Int {
        min(max(percentage, 0), 100)
    }

    static func progressFraction(_ percentage: Int) -> Double {
        Double(boundedPercentage(percentage)) / 100
    }

    static func pressure(for percentage: Int) -> SessionContextPressure {
        switch boundedPercentage(percentage) {
        case 95...: .critical
        case 80...: .elevated
        default: .normal
        }
    }

    static func canMutate(
        isConnected: Bool,
        isAgentActive: Bool,
        isCompacting: Bool,
        isBusy: Bool
    ) -> Bool {
        isConnected && !isAgentActive && !isCompacting && !isBusy
    }

    static func mutationUnavailableReason(
        isConnected: Bool,
        isAgentActive: Bool,
        isCompacting: Bool
    ) -> String? {
        if !isConnected { return "Reconnect to change the model or fork this session." }
        if isCompacting { return "Wait for context compaction to finish." }
        if isAgentActive { return "Wait for the current response to finish." }
        return nil
    }

    static func hasSessionUsage(inputTokens: Int, outputTokens: Int, cost: Double) -> Bool {
        inputTokens > 0 || outputTokens > 0 || cost > 0
    }

    static func deliveryWaitEmptyState(
        error: String?,
        isLoading: Bool,
        hasLoadedSnapshot: Bool
    ) -> String {
        if let error {
            return error
        }
        if isLoading, !hasLoadedSnapshot {
            return "Loading durable update state…"
        }
        return "No deliveries or waits are recorded."
    }

    static func cacheReadPercentage(cacheReadTokens: Int, totalInputTokens: Int) -> Int {
        guard cacheReadTokens > 0, totalInputTokens > 0 else { return 0 }
        let ratio = Double(cacheReadTokens) / Double(totalInputTokens)
        return min(100, max(0, Int((ratio * 100).rounded())))
    }

    static func automaticContextChannel(_ evaluation: ContextAutomaticEvaluationDTO) -> String {
        switch evaluation.deliveryChannel {
        case "reference":
            "Reference context"
        case "none":
            "Not delivered"
        case .some(let channel):
            WorkerConsolePresentation.displayLabel(channel)
        case nil where evaluation.narrative?.isEmpty == false:
            "System context (historical)"
        case nil:
            "Not delivered"
        }
    }

    static func modelDisplayName(
        _ modelId: String?,
        models: [ModelInfo],
        fallback: String
    ) -> String {
        guard let modelId, !modelId.isEmpty else { return fallback }
        if let model = ModelInfo.matching(modelId, in: models) {
            return model.formattedModelName
        }
        return formatModelDisplayName(modelId)
    }

    static func remainingContextText(currentContextWindow: Int, tokensRemaining: Int) -> String {
        guard currentContextWindow > 0 else { return "Context usage" }
        return "\(TokenFormatter.format(tokensRemaining, style: .withSuffix)) left"
    }

    static func resolvedContextWindow(trackedWindow: Int, modelWindow: Int?) -> Int {
        if let modelWindow, modelWindow > 0 {
            return modelWindow
        }
        return max(0, trackedWindow)
    }

    static func contextPercentage(tokensUsed: Int, contextWindow: Int) -> Int {
        guard tokensUsed > 0, contextWindow > 0 else { return 0 }
        return boundedPercentage(
            Int((Double(tokensUsed) / Double(contextWindow) * 100).rounded())
        )
    }

    static func causalGroups(_ runs: [WorkerInvocationDTO]) -> [SessionWorkerRunGroup] {
        let byParent = Dictionary(grouping: runs.compactMap { run -> (String, WorkerInvocationDTO)? in
            run.parentWorkerInvocationId.map { ($0, run) }
        }, by: \.0)
        let known = Set(runs.map(\.invocationId))
        let roots = runs.filter {
            $0.parentWorkerInvocationId == nil
                || !known.contains($0.parentWorkerInvocationId ?? "")
        }

        func descendants(of invocationId: String) -> [WorkerInvocationDTO] {
            (byParent[invocationId] ?? []).flatMap { pair in
                [pair.1] + descendants(of: pair.1.invocationId)
            }
        }

        return roots.map {
            SessionWorkerRunGroup(root: $0, descendants: descendants(of: $0.invocationId))
        }
    }

    static func runState(_ run: WorkerInvocationDTO) -> String {
        if run.detachedAt != nil,
           run.status == "queued" || run.status == "running" {
            return "Detached"
        }
        return WorkerConsolePresentation.displayLabel(run.status)
    }

    static func workerSelections(from toolSurface: AnyCodable?) -> [SessionContextWorkerSelection] {
        guard let surface = toolSurface?.dictionaryValue,
              let rawWorkers = surface["availableWorkers"] as? [Any] else {
            return []
        }
        return rawWorkers.compactMap { raw in
            guard let worker = AnyCodable(raw).dictionaryValue,
                  let workerId = worker["workerId"] as? String,
                  let modelName = worker["modelName"] as? String else {
                return nil
            }
            return SessionContextWorkerSelection(
                workerId: workerId,
                modelName: modelName,
                workerVersion: worker["workerVersion"] as? String,
                projected: worker["projected"] as? Bool ?? false,
                selectionReason: worker["selectionReason"] as? String,
                omissionReason: worker["omissionReason"] as? String,
                mechanism: worker["rankingMechanism"] as? String,
                score: (worker["relevanceScore"] as? Int) ?? 0,
                explanation: worker["routerExplanation"] as? String
            )
        }
    }

    static func fixedToolSelections(
        from toolSurface: AnyCodable?
    ) -> [SessionContextFixedToolSelection] {
        guard let surface = toolSurface?.dictionaryValue,
              let rawTools = surface["fixedTools"] as? [Any] else {
            return []
        }
        return rawTools.compactMap { raw in
            guard let tool = AnyCodable(raw).dictionaryValue,
                  let functionId = tool["functionId"] as? String,
                  let modelName = tool["modelName"] as? String else {
                return nil
            }
            return SessionContextFixedToolSelection(
                functionId: functionId,
                modelName: modelName,
                projected: tool["exposed"] as? Bool ?? false,
                audience: tool["audience"] as? String,
                accessPath: tool["accessPath"] as? String,
                selectionReason: tool["selectionReason"] as? String,
                omissionReason: tool["omissionReason"] as? String
            )
        }
    }

    static func toolSummary(
        fixed: [SessionContextFixedToolSelection],
        workers: [SessionContextWorkerSelection]
    ) -> SessionContextToolSummary {
        let fixedAvailable = fixed.filter(\.projected).count
        let workersAvailable = workers.filter(\.projected).count
        return SessionContextToolSummary(
            fixedAvailable: fixedAvailable,
            workersAvailable: workersAvailable,
            omitted: fixed.count - fixedAvailable + workers.count - workersAvailable
        )
    }

    static func agentUpdateTitle(
        sourceKind: String,
        sourceWorkerId: String?,
        sourceWorkerName: String? = nil
    ) -> String {
        sourceWorkerName
            ?? WorkerConsolePresentation.displayLabel(sourceWorkerId ?? sourceKind)
    }

    static func includedDeliveryTitle(sourceKind: String, content: String) -> String {
        guard sourceKind == "worker_result",
              let object = jsonObject(content)
        else {
            return WorkerConsolePresentation.displayLabel(sourceKind)
        }
        if let workerName = object["workerName"] as? String {
            return workerName
        }
        let waitEvidence = waitEvidence(in: object)
        let workerNames = waitEvidence
            .compactMap { $0["workerName"] as? String }
        if Set(workerNames).count == 1, let workerName = workerNames.first {
            return workerName
        }
        if let workerId = object["workerId"] as? String {
            return WorkerConsolePresentation.displayLabel(workerId)
        }
        let workerIds = waitEvidence
            .compactMap { $0["workerId"] as? String }
        if Set(workerIds).count == 1, let workerId = workerIds.first {
            return WorkerConsolePresentation.displayLabel(workerId)
        }
        return "Worker update"
    }

    static func includedDeliverySummary(sourceKind: String, content: String) -> String {
        guard sourceKind == "worker_result",
              let object = jsonObject(content)
        else {
            return content.truncated(to: 320)
        }
        switch object["kind"] as? String {
        case "worker_result":
            let status = object["status"] as? String ?? "completed"
            let evidence = object["evidence"] as? [String: Any] ?? [:]
            return readableWorkerEvidence(status: status, evidence: evidence)
        case "worker_wait":
            let evidence = waitEvidence(in: object)
            guard let first = evidence.first else {
                return "The requested worker wait completed."
            }
            let summary = readableWorkerEvidence(
                status: first["status"] as? String ?? "completed",
                evidence: first["evidence"] as? [String: Any] ?? first
            )
            if evidence.count == 1 {
                return summary
            }
            return "\(evidence.count) worker results are ready. \(summary)"
                .truncated(to: 320)
        default:
            return "A durable worker result was included in this model request."
        }
    }

    static func agentUpdateStatusLabel(status: String, wakePolicy: String) -> String {
        switch status {
        case "pending" where wakePolicy == "wake": "Will resume"
        case "pending": "Available"
        case "prepared": "In request"
        case "observed": "Seen"
        case "retry_exhausted": "Resume failed"
        default: WorkerConsolePresentation.displayLabel(status)
        }
    }

    static func agentUpdateStateDescription(
        status: String,
        wakePolicy: String,
        boundary: String
    ) -> String {
        switch status {
        case "pending" where wakePolicy == "wake" && boundary == "next_run":
            "Ready to resume this task in a new continuation."
        case "pending" where wakePolicy == "wake":
            "Ready to resume automatically at the next safe turn."
        case "pending":
            "Available for the next natural turn; it will not resume this task."
        case "prepared":
            "Included in an active model request."
        case "observed":
            "Included in a completed model turn."
        case "stale":
            "Retained for audit; it will not enter a future turn."
        case "cancelled":
            "Cancelled before it entered a model turn."
        case "retry_exhausted":
            "Automatic resume failed; the update remains available passively."
        default:
            WorkerConsolePresentation.displayLabel(status)
        }
    }

    static func agentWaitTitle(status: String) -> String {
        status == "pending" ? "Waiting for workers" : "Worker wait resolved"
    }

    static func agentWaitStatusLabel(status: String) -> String {
        status == "pending" ? "Auto-resume" : WorkerConsolePresentation.displayLabel(status)
    }

    static func agentWaitDescription(status: String, mode: String) -> String {
        guard status == "pending" else {
            return "The completion update is ready for delivery."
        }
        return mode == "any"
            ? "This task resumes when any selected worker finishes."
            : "This task resumes when all selected workers finish."
    }

    static func isActiveAgentUpdate(status: String) -> Bool {
        ["pending", "prepared", "retry_exhausted"].contains(status)
    }

    static func isActiveAgentWait(status: String) -> Bool {
        status == "pending"
    }

    static func shouldContinueObservingDeliveryState(
        isAgentActive: Bool,
        hasRunningWorker: Bool,
        updates: [(status: String, wakePolicy: String)],
        waitStatuses: [String]
    ) -> Bool {
        isAgentActive
            || hasRunningWorker
            || updates.contains {
                $0.status == "prepared"
                    || ($0.status == "pending" && $0.wakePolicy == "wake")
            }
            || waitStatuses.contains { isActiveAgentWait(status: $0) }
    }

    private static func jsonObject(_ content: String) -> [String: Any]? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func waitEvidence(in object: [String: Any]) -> [[String: Any]] {
        (object["results"] as? [[String: Any]] ?? []).compactMap { result in
            guard let content = result["evidence"] as? String,
                  let evidence = jsonObject(content)
            else {
                return nil
            }
            return evidence
        }
    }

    private static func readableWorkerEvidence(
        status: String,
        evidence: [String: Any]
    ) -> String {
        let text = ["preview", "summary", "message"]
            .compactMap { evidence[$0] as? String }
            .first?
            .trimmed
        let error = ["error", "reason"]
            .compactMap { evidence[$0] as? String }
            .first?
            .trimmed
        switch status {
        case "failed":
            return error.map { "Failed: \($0)" } ?? "Worker execution failed."
        case "cancelled":
            return error.map { "Cancelled: \($0)" } ?? "Worker execution was cancelled."
        default:
            if text?.lowercased() == "empty" {
                return "Completed without a user-facing result summary."
            }
            return text?.nilIfEmpty
                ?? "Worker completed. Open the exact content for technical details."
        }
    }
}

struct SessionContextToolSummary: Equatable, Sendable {
    let fixedAvailable: Int
    let workersAvailable: Int
    let omitted: Int
}

struct SessionContextFixedToolSelection: Identifiable, Equatable {
    let functionId: String
    let modelName: String
    let projected: Bool
    let audience: String?
    let accessPath: String?
    let selectionReason: String?
    let omissionReason: String?

    var id: String { functionId }
}

struct SessionContextWorkerSelection: Identifiable, Equatable {
    let workerId: String
    let modelName: String
    let workerVersion: String?
    let projected: Bool
    let selectionReason: String?
    let omissionReason: String?
    let mechanism: String?
    let score: Int
    let explanation: String?

    var id: String { workerId }
}

struct SessionWorkerRunGroup: Identifiable, Equatable {
    let root: WorkerInvocationDTO
    let descendants: [WorkerInvocationDTO]

    var id: String { root.invocationId }
}

/// Session-scoped context telemetry, worker activity, and controls backed only
/// by durable engine truth: token records, originating-session worker runs, the
/// model catalog/switch operation, automatic compaction state, and forking.
