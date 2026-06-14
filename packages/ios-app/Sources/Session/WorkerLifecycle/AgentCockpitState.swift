import Foundation

enum AgentCockpitStatusKind: String, Equatable, Sendable {
    case offline
    case connecting
    case idle
    case ready
    case running
    case awaitingApproval
    case degraded
}

struct AgentCockpitStatusSummary: Equatable, Sendable {
    var kind: AgentCockpitStatusKind
    var title: String
    var detail: String
    var systemImage: String
}

struct AgentCockpitWorkerRow: Equatable, Identifiable, Sendable {
    var id: String
    var kind: String
    var lifecycle: String
    var visibility: String
    var ownerActor: String
    var authorityGrant: String
    var namespaceClaims: [String]
    var functionCount: Int
    var triggerCount: Int
    var functionIds: [String]
    var triggerIds: [String]
}

struct AgentCockpitFunctionRow: Equatable, Identifiable, Sendable {
    var id: String
    var ownerWorker: String
    var description: String
    var visibility: String
    var effectClass: String
    var riskLevel: String
    var health: String
    var tags: [String]
}

struct AgentCockpitTriggerRow: Equatable, Identifiable, Sendable {
    var id: String
    var ownerWorker: String
    var triggerType: String
    var targetFunction: String
    var deliveryMode: String
    var visibility: String
}

struct AgentCockpitPackageRow: Equatable, Identifiable, Sendable {
    var id: String
    var kind: WorkerLifecycleResourceKind
    var packageId: String
    var packageVersion: String
    var lifecycle: String
    var resourceId: String
    var currentVersionId: String?
    var updatedAt: String?

    var displayName: String {
        packageId.isEmpty ? resourceId : "\(packageId) \(packageVersion)"
    }
}

struct AgentCockpitActivityItem: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
    var timestamp: String?
    var systemImage: String
}

struct AgentCockpitRuntimeSurface: Equatable, Identifiable, Sendable {
    var surface: UiSurfaceDTO
    var resourceRef: UiSurfaceRefDTO
    var lifecycle: String
    var updatedAt: String?

    var id: String { resourceRef.resourceId }
}

enum AgentCockpitActionKind: String, Equatable, Sendable {
    case installProposal
    case enablePackage
    case disablePackage
    case launchWorker
    case stopWorker
    case retirePackage
}

struct AgentCockpitAction: Equatable, Identifiable, Sendable {
    var id: String
    var kind: AgentCockpitActionKind
    var title: String
    var packageId: String?
    var packageVersion: String?
    var proposalResourceId: String?
    var launchAttemptResourceId: String?
    var reason: String
    var disabledReason: String?
    var isDestructive: Bool

    var isEnabled: Bool { disabledReason == nil }
}

struct AgentCockpitConfirmation: Equatable, Identifiable, Sendable {
    var id: String { action.id }
    var action: AgentCockpitAction
    var title: String
    var message: String
    var confirmLabel: String
}

struct AgentCockpitOverview: Equatable, Sendable {
    var status: AgentCockpitStatusSummary
    var workers: [AgentCockpitWorkerRow]
    var functions: [AgentCockpitFunctionRow]
    var triggers: [AgentCockpitTriggerRow]
    var triggerTypes: [TriggerTypeCatalogDefinitionDTO]
    var packages: [AgentCockpitPackageRow]
    var runtimeSurfaces: [AgentCockpitRuntimeSurface]
    var activity: [AgentCockpitActivityItem]
    var currentRevision: UInt64?
    var nextRevision: UInt64?

    static func empty(connectionState: ConnectionState) -> AgentCockpitOverview {
        AgentCockpitOverview(
            status: AgentCockpitProjection.status(
                connectionState: connectionState,
                workers: [],
                functions: [],
                packages: []
            ),
            workers: [],
            functions: [],
            triggers: [],
            triggerTypes: [],
            packages: [],
            runtimeSurfaces: [],
            activity: [],
            currentRevision: nil,
            nextRevision: nil
        )
    }
}

enum AgentCockpitProjection {
    static func project(
        snapshot: CatalogWatchSnapshotDTO,
        resources: [EngineResourceDTO],
        runtimeSurfaces: [AgentCockpitRuntimeSurface] = [],
        connectionState: ConnectionState
    ) -> AgentCockpitOverview {
        let snapshotBody = snapshot.snapshot
        let functions = (snapshotBody?.functionDefinitions() ?? []).map(functionRow)
            .sorted { $0.id < $1.id }
        let triggers = (snapshotBody?.triggerDefinitions() ?? []).map(triggerRow)
            .sorted { $0.id < $1.id }
        let triggerTypes = (snapshotBody?.triggerTypeDefinitions() ?? [])
            .sorted { $0.id < $1.id }
        let workers = (snapshotBody?.workerDefinitions() ?? []).map { worker in
            workerRow(worker, functions: functions, triggers: triggers)
        }
        .sorted { $0.id < $1.id }
        let packages = resources.compactMap(packageRow)
            .sorted { lhs, rhs in
                if lhs.packageId == rhs.packageId {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.packageId < rhs.packageId
            }
        let activity = activityItems(changes: snapshot.changes ?? [], packages: packages)
        return AgentCockpitOverview(
            status: status(
                connectionState: connectionState,
                workers: workers,
                functions: functions,
                packages: packages
            ),
            workers: workers,
            functions: functions,
            triggers: triggers,
            triggerTypes: triggerTypes,
            packages: packages,
            runtimeSurfaces: runtimeSurfaces.sorted { $0.surface.title < $1.surface.title },
            activity: activity,
            currentRevision: snapshot.currentRevision,
            nextRevision: snapshot.nextRevision
        )
    }

    static func status(
        connectionState: ConnectionState,
        workers: [AgentCockpitWorkerRow],
        functions: [AgentCockpitFunctionRow],
        packages: [AgentCockpitPackageRow]
    ) -> AgentCockpitStatusSummary {
        if !connectionState.isConnected {
            switch connectionState {
            case .connecting, .reconnecting, .deployRestarting:
                return .init(
                    kind: .connecting,
                    title: "Connecting",
                    detail: "Rebuilding the engine link",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
            case .unauthorized:
                return .init(
                    kind: .degraded,
                    title: "Pairing Required",
                    detail: "Server authentication needs attention",
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
            case .failed:
                return .init(
                    kind: .degraded,
                    title: "Connection Failed",
                    detail: "The engine is unreachable",
                    systemImage: "exclamationmark.triangle"
                )
            case .disconnected:
                return .init(
                    kind: .offline,
                    title: "Offline",
                    detail: "No active engine connection",
                    systemImage: "wifi.slash"
                )
            case .connected:
                break
            }
        }

        if packages.contains(where: { $0.kind == .proposal && normalized($0.lifecycle) == "proposed" }) {
            return .init(
                kind: .awaitingApproval,
                title: "Approval Needed",
                detail: "A worker package is waiting for review",
                systemImage: "checkmark.seal"
            )
        }
        if workers.contains(where: { normalized($0.lifecycle) == "degraded" })
            || functions.contains(where: { ["degraded", "unhealthy", "unknown"].contains(normalized($0.health)) }) {
            return .init(
                kind: .degraded,
                title: "Degraded",
                detail: "One or more workers need attention",
                systemImage: "waveform.path.ecg"
            )
        }
        if workers.contains(where: { ["starting", "ready", "draining"].contains(normalized($0.lifecycle)) }) {
            return .init(
                kind: .ready,
                title: "Ready",
                detail: "\(workers.count) workers, \(functions.count) functions",
                systemImage: "cpu"
            )
        }
        return .init(
            kind: .idle,
            title: "Idle",
            detail: "No active workers published yet",
            systemImage: "circle.dotted"
        )
    }

    static func actions(for package: AgentCockpitPackageRow) -> [AgentCockpitAction] {
        let lifecycle = normalized(package.lifecycle)
        let identityMissing = package.packageId.isEmpty || package.packageVersion.isEmpty
        let identityDisabled = identityMissing ? "Package identity is not available" : nil
        switch package.kind {
        case .proposal:
            return [
                .init(
                    id: "install:\(package.resourceId)",
                    kind: .installProposal,
                    title: "Install",
                    packageId: package.packageId,
                    packageVersion: package.packageVersion,
                    proposalResourceId: package.resourceId,
                    launchAttemptResourceId: nil,
                    reason: "user approved package proposal",
                    disabledReason: lifecycle == "proposed" ? identityDisabled : "Only proposed packages can be installed",
                    isDestructive: false
                )
            ]
        case .package, .installation:
            return [
                .init(
                    id: "enable:\(package.resourceId)",
                    kind: .enablePackage,
                    title: "Enable",
                    packageId: package.packageId,
                    packageVersion: package.packageVersion,
                    proposalResourceId: nil,
                    launchAttemptResourceId: nil,
                    reason: "user enabled package from cockpit",
                    disabledReason: ["installed", "disabled", "stopped"].contains(lifecycle) ? identityDisabled : "Package is not enable-ready",
                    isDestructive: false
                ),
                .init(
                    id: "launch:\(package.resourceId)",
                    kind: .launchWorker,
                    title: "Launch",
                    packageId: package.packageId,
                    packageVersion: package.packageVersion,
                    proposalResourceId: nil,
                    launchAttemptResourceId: nil,
                    reason: "user launched worker from cockpit",
                    disabledReason: lifecycle == "enabled" ? identityDisabled : "Package must be enabled before launch",
                    isDestructive: false
                ),
                .init(
                    id: "disable:\(package.resourceId)",
                    kind: .disablePackage,
                    title: "Disable",
                    packageId: package.packageId,
                    packageVersion: package.packageVersion,
                    proposalResourceId: nil,
                    launchAttemptResourceId: nil,
                    reason: "user disabled package from cockpit",
                    disabledReason: ["enabled", "launched", "stopped"].contains(lifecycle) ? identityDisabled : "Package is not enabled",
                    isDestructive: true
                ),
                .init(
                    id: "retire:\(package.resourceId)",
                    kind: .retirePackage,
                    title: "Retire",
                    packageId: package.packageId,
                    packageVersion: package.packageVersion,
                    proposalResourceId: nil,
                    launchAttemptResourceId: nil,
                    reason: "user retired package from cockpit",
                    disabledReason: lifecycle == "retired" ? "Package is already retired" : identityDisabled,
                    isDestructive: true
                )
            ]
        case .launchAttempt:
            return [
                .init(
                    id: "stop:\(package.resourceId)",
                    kind: .stopWorker,
                    title: "Stop",
                    packageId: nil,
                    packageVersion: nil,
                    proposalResourceId: nil,
                    launchAttemptResourceId: package.resourceId,
                    reason: "user stopped worker from cockpit",
                    disabledReason: ["launched", "running"].contains(lifecycle) ? nil : "Launch attempt is not running",
                    isDestructive: true
                )
            ]
        case .conformanceReport:
            return []
        case .uiSurface:
            return []
        }
    }

    static func confirmation(for action: AgentCockpitAction) -> AgentCockpitConfirmation {
        let target: String = {
            if let packageId = action.packageId, let packageVersion = action.packageVersion {
                return "\(packageId) \(packageVersion)"
            }
            return action.launchAttemptResourceId ?? "this worker lifecycle item"
        }()
        let message: String
        switch action.kind {
        case .installProposal:
            message = "Install \(target). The engine will validate the manifest and create package evidence before it can run."
        case .enablePackage:
            message = "Enable \(target). Enabled packages can be launched by the worker runtime."
        case .disablePackage:
            message = "Disable \(target). Existing launched work may need to be stopped separately."
        case .launchWorker:
            message = "Launch \(target). The engine will start the local worker and record conformance evidence."
        case .stopWorker:
            message = "Stop \(target). The engine records the stop path as lifecycle evidence."
        case .retirePackage:
            message = "Retire \(target). Retired packages are kept as evidence but should not be launched."
        }
        return AgentCockpitConfirmation(
            action: action,
            title: action.title,
            message: message,
            confirmLabel: action.title
        )
    }

    private static func workerRow(
        _ worker: WorkerCatalogDefinitionDTO,
        functions: [AgentCockpitFunctionRow],
        triggers: [AgentCockpitTriggerRow]
    ) -> AgentCockpitWorkerRow {
        let ownedFunctions = functions.filter { $0.ownerWorker == worker.id }
        let ownedTriggers = triggers.filter { $0.ownerWorker == worker.id }
        return AgentCockpitWorkerRow(
            id: worker.id,
            kind: worker.kind ?? "Unknown",
            lifecycle: worker.lifecycle ?? "Unknown",
            visibility: worker.visibility ?? "unknown",
            ownerActor: worker.ownerActor ?? "unknown",
            authorityGrant: worker.authorityGrant ?? "unknown",
            namespaceClaims: worker.namespaceClaims ?? [],
            functionCount: ownedFunctions.count,
            triggerCount: ownedTriggers.count,
            functionIds: ownedFunctions.map(\.id),
            triggerIds: ownedTriggers.map(\.id)
        )
    }

    private static func functionRow(_ function: FunctionCatalogDefinitionDTO) -> AgentCockpitFunctionRow {
        AgentCockpitFunctionRow(
            id: function.id,
            ownerWorker: function.ownerWorker ?? "unknown",
            description: function.description ?? "",
            visibility: function.visibility ?? "unknown",
            effectClass: function.effectClass ?? "unknown",
            riskLevel: function.riskLevel ?? "unknown",
            health: function.health ?? "unknown",
            tags: function.tags ?? []
        )
    }

    private static func triggerRow(_ trigger: TriggerCatalogDefinitionDTO) -> AgentCockpitTriggerRow {
        AgentCockpitTriggerRow(
            id: trigger.id,
            ownerWorker: trigger.ownerWorker ?? "unknown",
            triggerType: trigger.triggerType ?? "unknown",
            targetFunction: trigger.targetFunction ?? "unknown",
            deliveryMode: trigger.deliveryMode ?? "unknown",
            visibility: trigger.visibility ?? "unknown"
        )
    }

    private static func packageRow(_ resource: EngineResourceDTO) -> AgentCockpitPackageRow? {
        guard let kind = WorkerLifecycleResourceKind(rawValue: resource.kind) else { return nil }
        guard kind != .uiSurface else { return nil }
        let parts = resource.resourceId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let packageId = parts.count > 1 ? parts[1] : ""
        let packageVersion = parts.count > 2 ? parts[2] : ""
        return AgentCockpitPackageRow(
            id: resource.resourceId,
            kind: kind,
            packageId: packageId,
            packageVersion: packageVersion,
            lifecycle: resource.lifecycle,
            resourceId: resource.resourceId,
            currentVersionId: resource.currentVersionId,
            updatedAt: resource.updatedAt
        )
    }

    private static func activityItems(
        changes: [CatalogChangeDTO],
        packages: [AgentCockpitPackageRow]
    ) -> [AgentCockpitActivityItem] {
        let catalogItems = changes.suffix(8).reversed().map { change in
            AgentCockpitActivityItem(
                id: change.id ?? "\(change.subjectId ?? "catalog")-\(change.afterRevision ?? 0)",
                title: title(for: change),
                detail: [change.subjectKind, change.subjectId].compactMap { $0 }.joined(separator: " "),
                timestamp: change.timestamp,
                systemImage: image(for: change.subjectKind)
            )
        }
        let packageItems = packages.prefix(6).map { package in
            AgentCockpitActivityItem(
                id: "resource:\(package.resourceId)",
                title: "\(package.kind.rawValue.replacingOccurrences(of: "_", with: " ")) \(package.lifecycle)",
                detail: package.displayName,
                timestamp: package.updatedAt,
                systemImage: package.kind == .proposal ? "checkmark.seal" : "shippingbox"
            )
        }
        return Array((packageItems + catalogItems).prefix(12))
    }

    private static func title(for change: CatalogChangeDTO) -> String {
        let kind = change.kind?.replacingOccurrences(of: "_", with: " ") ?? "catalog changed"
        return kind.prefix(1).uppercased() + kind.dropFirst()
    }

    private static func image(for subjectKind: String?) -> String {
        switch subjectKind {
        case "worker": return "cpu"
        case "function": return "function"
        case "trigger", "trigger_type": return "bolt"
        default: return "clock"
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }
}
