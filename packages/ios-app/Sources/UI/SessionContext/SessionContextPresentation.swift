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

    static func remainingContextText(currentContextWindow: Int, tokensRemaining: Int) -> String {
        guard currentContextWindow > 0 else { return "Window loading" }
        return "\(TokenFormatter.format(tokensRemaining, style: .withSuffix)) left"
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
