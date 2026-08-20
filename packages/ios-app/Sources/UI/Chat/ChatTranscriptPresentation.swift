import Foundation
import SwiftUI

enum ChatExtensionChromePolicy {
    // Canonical extension state continues to flow. These presentation gates stay
    // explicit so native widgets/statuses can be restored only after their layout
    // mutations participate in the chat viewport transaction.
    static let rendersWidgets = true
    static let rendersStatusPills = false
}

struct ChatExtensionWidgetItem: Identifiable, Hashable {
    enum Content: Hashable {
        case semantic(ExtensionWidget)
        case surface(ExtensionSurface)
    }
    let id: String
    let content: Content
}

struct ExtensionInteractionScope: Equatable, Hashable, Sendable {
    let id: String
    let hostEpoch: String
    let presentationRevision: Int

    init(_ interaction: ExtensionInteraction) {
        id = interaction.id
        hostEpoch = interaction.hostEpoch
        presentationRevision = interaction.presentationRevision
    }
}

enum ChatExtensionForegroundPresentation: Equatable {
    case none
    case interaction
    case editorRequest
}

enum ChatExtensionPresentationArbiter {
    /// Semantic questions have deterministic priority over draft replacement
    /// confirmation. The lower-priority request remains in the authoritative
    /// store and is presented after the interaction settles.
    static func presentation(
        modelSettled: Bool,
        hasInteraction: Bool,
        hasEditorRequest: Bool
    ) -> ChatExtensionForegroundPresentation {
        guard modelSettled else { return .none }
        if hasInteraction { return .interaction }
        if hasEditorRequest { return .editorRequest }
        return .none
    }
}

enum ChatExtensionInteractionPolicy {
    static func presentedInteraction(
        _ interactions: [ExtensionInteraction],
        suppressing scope: ExtensionInteractionScope?
    ) -> ExtensionInteraction? {
        interactions.first { interaction in
            guard let scope else { return true }
            return ExtensionInteractionScope(interaction) != scope
        }
    }

    static func shouldClearSuppression(
        _ scope: ExtensionInteractionScope,
        from interactions: [ExtensionInteraction]
    ) -> Bool {
        !interactions.contains { ExtensionInteractionScope($0) == scope }
    }
}

struct ExtensionActivityStatus: Identifiable, Hashable, Sendable {
    /// The complete admitted key is identity. Display truncation is separate so
    /// two 256-byte keys sharing a long prefix never collapse into one row.
    let key: String
    let displayKey: String
    let value: String
    var id: String { key }
}

struct ExtensionActivityServiceItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let status: String
    /// Bounded text shown in the native card.
    let source: String
    /// The canonical source used for owner matching. Display truncation must
    /// never change grouping identity.
    let matchingSource: String
    let error: Bool
}

struct ExtensionActivitySummary: Hashable, Sendable {
    let label: String
    let statusCount: Int
    let widgetCount: Int
    let serviceCount: Int
    let runningServiceCount: Int
    let services: [ExtensionActivityServiceItem]

    var totalCount: Int { statusCount + widgetCount + serviceCount }
}

/// A separately addressable native extension affordance. Group identity comes
/// only from admitted public identity: semantic widget keys, decoded host
/// surface identity, or explicit surface provenance.
struct ExtensionWidgetGroup: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let items: [ChatExtensionWidgetItem]
    let statuses: [ExtensionActivityStatus]
    let services: [ExtensionActivityServiceItem]
    let activities: [ExtensionRunActivity]

    var isWidgetGroup: Bool { !items.isEmpty }
    var liveActivityCount: Int { activities.filter(\.isLive).count + services.filter { $0.status == "Running" }.count }
    var hasLiveContent: Bool { !items.isEmpty || !statuses.isEmpty || liveActivityCount > 0 }
}

enum ChatExtensionWidgetPolicy {
    static let maximumStackHeight: CGFloat = 220
    static let maximumStatuses = 16
    static let maximumStatusValueCharacters = 512
    static let maximumWidgets = 24
    static let maximumWidgetLines = 200
    static let maximumServiceItems = 24
    static let maximumActivities = 64

    static func bounded(_ value: String, maximum: Int) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maximum else { return clean }
        return String(clean.prefix(maximum - 1)) + "…"
    }

    static func admittedStatuses(_ statuses: [String: String]) -> [ExtensionActivityStatus] {
        statuses
            .compactMap { key, value -> ExtensionActivityStatus? in
                let displayKey = bounded(key, maximum: 128)
                let boundedValue = bounded(value, maximum: maximumStatusValueCharacters)
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !boundedValue.isEmpty else { return nil }
                return ExtensionActivityStatus(key: key, displayKey: displayKey, value: boundedValue)
            }
            .sorted { $0.key < $1.key }
            .prefix(maximumStatuses)
            .map { $0 }
    }

    static func admittedItems(_ presentation: ExtensionPresentationState) -> [ChatExtensionWidgetItem] {
        Array((mergedItems(widgets: presentation.semanticState.widgets, surfaces: presentation.surfaces, placement: .aboveEditor)
            + mergedItems(widgets: presentation.semanticState.widgets, surfaces: presentation.surfaces, placement: .belowEditor)).prefix(maximumWidgets))
    }

    static func serviceItems(_ executions: [ToolExecutionState]) -> [ExtensionActivityServiceItem] {
        executions
            .filter { $0.extensionOrigin != nil }
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return (lhs.order ?? Int.max) < (rhs.order ?? Int.max) }
                return lhs.toolCallId < rhs.toolCallId
            }
            .prefix(maximumServiceItems)
            .map {
                ExtensionActivityServiceItem(
                    id: $0.toolCallId,
                    title: bounded($0.toolName, maximum: 96),
                    status: $0.status == .running ? "Running" : ($0.status == .failed ? "Failed" : "Completed"),
                    source: bounded($0.extensionOrigin?.source ?? "Extension", maximum: 128),
                    matchingSource: $0.extensionOrigin?.source ?? "Extension",
                    error: $0.isError
                )
            }
    }

    static func orderedActivities(_ activities: [ExtensionRunActivity]) -> [ExtensionRunActivity] {
        activities.sorted { left, right in
            if left.isLive != right.isLive { return left.isLive }
            let leftActivity = left.lastActivityAt ?? left.updatedAt
            let rightActivity = right.lastActivityAt ?? right.updatedAt
            if leftActivity != rightActivity { return leftActivity > rightActivity }
            if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
            return left.id < right.id
        }
    }

    static func groups(
        _ presentation: ExtensionPresentationState,
        executions: [ToolExecutionState] = [],
        activities: [ExtensionRunActivity] = []
    ) -> [ExtensionWidgetGroup] {
        let statuses = admittedStatuses(presentation.semanticState.statuses)
        let admittedActivities = Array(orderedActivities(activities).prefix(maximumActivities))
        let activityToolIDs = Set(admittedActivities.map(\.toolCallId))
        let services = serviceItems(executions).filter { !activityToolIDs.contains($0.id) }
        var owners: [String: ExtensionOwner] = [:]
        for owner in presentation.semanticState.widgets.compactMap(\.owner) + Array(presentation.semanticState.statusOwners.values) {
            owners[owner.id] = owner
        }
        var ownerBySource: [String: ExtensionOwner] = [:]
        var ambiguousSources = Set<String>()
        for owner in owners.values {
            if let previous = ownerBySource[owner.source], previous.id != owner.id { ambiguousSources.insert(owner.source) }
            else { ownerBySource[owner.source] = owner }
        }
        for source in ambiguousSources { ownerBySource[source] = nil }
        var matchedStatusKeys = Set<String>()
        var matchedServiceIDs = Set<String>()
        var groups: [String: ExtensionWidgetGroup] = [:]
        var semanticGroups: [String: String] = [:]

        func ownerID(_ owner: ExtensionOwner) -> String { "owner:\(owner.id)" }
        func add(_ groupID: String, label: String, item: ChatExtensionWidgetItem? = nil,
                 status: ExtensionActivityStatus? = nil, serviceItems: [ExtensionActivityServiceItem] = [],
                 activities: [ExtensionRunActivity] = [], replaceLabel: Bool = false) {
            let old = groups[groupID]
            groups[groupID] = ExtensionWidgetGroup(
                id: groupID, label: bounded(replaceLabel ? label : (old?.label ?? label), maximum: 64),
                items: (old?.items ?? []) + (item.map { [$0] } ?? []),
                statuses: {
                    let existing = old?.statuses ?? []
                    guard let status, !existing.contains(where: { $0.key == status.key }) else { return existing }
                    return existing + [status]
                }(),
                services: (old?.services ?? []) + serviceItems,
                activities: (old?.activities ?? []) + activities
            )
        }

        for widget in presentation.semanticState.widgets.sorted(by: { $0.placement.rawValue == $1.placement.rawValue ? $0.key < $1.key : $0.placement.rawValue < $1.placement.rawValue }) {
            let groupID = widget.owner.map(ownerID) ?? "semantic:\(widget.key)"
            semanticGroups[widget.key] = groupID
            let status = statuses.first { $0.key == widget.key }
            if let status { matchedStatusKeys.insert(status.key) }
            add(groupID, label: widget.owner?.title ?? "Extension widget",
                 item: ChatExtensionWidgetItem(id: "semantic-widget:\(widget.key)", content: .semantic(widget)), status: status)
        }

        let surfaces = visibleSurfaces(presentation.surfaces, placement: .aboveEditor)
            + visibleSurfaces(presentation.surfaces, placement: .belowEditor)
        for surface in surfaces.sorted(by: { $0.id < $1.id }) {
            // A surface without Gateway provenance remains independently
            // addressable; never infer ownership from whichever activity is
            // newest, or create a competing Local group.
            let source = admittedSource(surface.provenance?.source)
            let canonicalKey = canonicalWidgetKey(for: surface.id)
            let owner = canonicalKey.flatMap { semanticGroups[$0].flatMap { groups[$0] }?.items.compactMap { item in
                if case .semantic(let widget) = item.content { return widget.owner }
                return nil
            }.first } ?? source.flatMap { ownerBySource[$0] }
            let groupID = canonicalKey.flatMap { semanticGroups[$0] }
                ?? owner.map(ownerID)
                ?? source.map { "source:\($0)" }
                ?? "surface:\(surface.id)"
            let status = canonicalKey.flatMap { key in statuses.first { $0.key == key } }
            if let status { matchedStatusKeys.insert(status.key) }
            let exactServices = (owner?.source ?? source).map { source in services.filter { $0.matchingSource == source } } ?? []
            let newServices = exactServices.filter { matchedServiceIDs.insert($0.id).inserted }
            add(groupID, label: owner?.title ?? source.map(humanizedSource) ?? "Extension widget",
                 item: ChatExtensionWidgetItem(id: "surface-widget:\(surface.id)", content: .surface(surface)), status: status, serviceItems: newServices)
        }

        for activity in admittedActivities {
            let owner = ownerBySource[activity.source.source]
            let groupID = owner.map(ownerID) ?? "source:\(activity.source.source)"
            let isLocalSubagent = activity.source.source == "local"
            let fallbackLabel = isLocalSubagent ? "Pi Subagents" : humanizedSource(activity.source.source)
            add(
                groupID,
                label: owner?.title ?? fallbackLabel,
                activities: [activity],
                replaceLabel: owner == nil && isLocalSubagent
            )
        }

        // Statuses and tools carry public source provenance. Only exact source
        // matches are attributed; unknown values remain one truthful fallback.
        for status in statuses where !matchedStatusKeys.contains(status.key) {
            if let owner = presentation.semanticState.statusOwners[status.key], owners[owner.id] != nil {
                matchedStatusKeys.insert(status.key)
                add(ownerID(owner), label: owner.title, status: status)
            }
        }
        for owner in owners.values.sorted(by: { $0.id < $1.id }) {
            let ownerServices = services.filter { $0.matchingSource == owner.source && matchedServiceIDs.insert($0.id).inserted }
            if !ownerServices.isEmpty { add(ownerID(owner), label: owner.title, serviceItems: ownerServices) }
        }

        let unmatchedStatuses = statuses.filter { !matchedStatusKeys.contains($0.key) }
        let unmatchedServiceValues = services.filter { !matchedServiceIDs.contains($0.id) }
        for source in Set(unmatchedServiceValues.map(\.matchingSource)).sorted() {
            let sourceServices = unmatchedServiceValues.filter { $0.matchingSource == source }
            add("source:\(source)", label: humanizedSource(source), serviceItems: sourceServices)
            sourceServices.forEach { matchedServiceIDs.insert($0.id) }
        }
        let unmatchedServices = services.filter { !matchedServiceIDs.contains($0.id) }
        let matchedActivityIDs = Set(groups.values.flatMap(\.activities).map(\.id))
        let unmatchedActivities = admittedActivities.filter { !matchedActivityIDs.contains($0.id) }
        if !unmatchedStatuses.isEmpty || !unmatchedServices.isEmpty || !unmatchedActivities.isEmpty {
            groups["activity"] = ExtensionWidgetGroup(
                id: "activity", label: "Extension activity", items: [], statuses: unmatchedStatuses,
                services: unmatchedServices, activities: unmatchedActivities
            )
        }
        return groups.values.sorted { $0.id < $1.id }
    }

    static func liveGroups(
        _ presentation: ExtensionPresentationState,
        executions: [ToolExecutionState] = [],
        activities: [ExtensionRunActivity] = []
    ) -> [ExtensionWidgetGroup] {
        groups(presentation, executions: executions, activities: activities).compactMap { group in
            let liveActivities = group.activities.filter(\.isLive)
            let liveServices = group.services.filter { $0.status == "Running" }
            // A structured activity owns the live presentation for its exact
            // provenance group. Do not let the retained opaque widget surface
            // reappear when the activity settles; that was the source of the
            // raw `async subagent … background` fallback returning after the
            // native sheet disappeared. Manage Session still receives the
            // complete group, including finished activities and any surface.
            let liveItems = group.activities.isEmpty ? group.items : []
            guard !liveItems.isEmpty || !group.statuses.isEmpty || !liveActivities.isEmpty || !liveServices.isEmpty else { return nil }
            return ExtensionWidgetGroup(
                id: group.id, label: group.label, items: liveItems, statuses: group.statuses,
                services: liveServices, activities: liveActivities
            )
        }
    }

    /// Reverses the host's opaque widget surface identity without relying on a
    /// package, widget name, or content convention. Any non-canonical ID fails
    /// closed and remains independently addressable.
    static func canonicalWidgetKey(for surfaceID: String) -> String? {
        guard let encoded = surfaceID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first,
              !encoded.isEmpty else { return nil }
        let normalized = String(encoded).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func admittedSource(_ source: String?) -> String? {
        guard let source else { return nil }
        let clean = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    static func humanizedSource(_ source: String) -> String {
        var normalized = source
        if normalized.hasPrefix("npm:") { normalized.removeFirst(4) }
        if let versionSeparator = normalized.lastIndex(of: "@"), versionSeparator > normalized.startIndex {
            normalized = String(normalized[..<versionSeparator])
        }
        let words = normalized.split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return "Extension widget" }
        return words.map { word in
            let value = String(word)
            return value.prefix(1).uppercased() + value.dropFirst()
        }.joined(separator: " ")
    }

    static func summary(
        _ presentation: ExtensionPresentationState,
        executions: [ToolExecutionState] = [],
        activities: [ExtensionRunActivity] = []
    ) -> ExtensionActivitySummary? {
        let statuses = admittedStatuses(presentation.semanticState.statuses)
        let items = admittedItems(presentation)
        let activities = Array(orderedActivities(activities).prefix(maximumActivities))
        let activityToolIDs = Set(activities.map(\.toolCallId))
        let services = serviceItems(executions).filter { !activityToolIDs.contains($0.id) }
        guard !statuses.isEmpty || !items.isEmpty || !services.isEmpty || !activities.isEmpty else { return nil }
        let running = services.filter { $0.status == "Running" }.count + activities.filter(\.isLive).count
        let label: String
        if running > 0 { label = running == 1 ? "Extension activity · 1 running" : "Extension activity · \(running) running" }
        else if statuses.count == 1 { label = bounded(statuses[0].value, maximum: 72) }
        else if items.count == 1 && statuses.isEmpty && services.isEmpty && activities.isEmpty { label = "Extension widget" }
        else { label = "Extension activity" }
        return ExtensionActivitySummary(label: label, statusCount: statuses.count, widgetCount: items.count, serviceCount: services.count + activities.count, runningServiceCount: running, services: services)
    }

    static func hasActivity(
        _ presentation: ExtensionPresentationState,
        executions: [ToolExecutionState] = [],
        activities: [ExtensionRunActivity] = []
    ) -> Bool {
        guard ChatExtensionChromePolicy.rendersWidgets else { return false }
        return summary(presentation, executions: executions, activities: activities) != nil
    }

    static func visibleWidgets(
        _ widgets: [ExtensionWidget],
        placement: ExtensionWidget.Placement
    ) -> [ExtensionWidget] {
        guard ChatExtensionChromePolicy.rendersWidgets else { return [] }
        return widgets.filter { $0.placement == placement }
    }

    static func visibleSurfaces(
        _ surfaces: [ExtensionSurface],
        placement: ExtensionSurface.Placement
    ) -> [ExtensionSurface] {
        guard ChatExtensionChromePolicy.rendersWidgets else { return [] }
        return surfaces
            .filter { $0.kind == .widget && $0.placement == placement && $0.inputMode == .none }
            .sorted { $0.id == $1.id ? $0.revision < $1.revision : $0.id < $1.id }
    }

    static func mergedItems(
        widgets: [ExtensionWidget],
        surfaces: [ExtensionSurface],
        placement: ExtensionWidget.Placement
    ) -> [ChatExtensionWidgetItem] {
        guard ChatExtensionChromePolicy.rendersWidgets else { return [] }
        let semantic = widgets.filter { $0.placement == placement }.map {
            ChatExtensionWidgetItem(id: "semantic-widget:\($0.key)", content: .semantic($0))
        }
        let remotePlacement: ExtensionSurface.Placement = placement == .aboveEditor ? .aboveEditor : .belowEditor
        let remote = visibleSurfaces(surfaces, placement: remotePlacement)
            .map { ChatExtensionWidgetItem(id: "surface-widget:\($0.id)", content: .surface($0)) }
        return (semantic + remote).sorted { $0.id < $1.id }
    }
}

/// Exact-target presentation-only outgoing state. This is never inserted into
/// the canonical transcript or JSONL; it disappears only after canonical user
/// message reconciliation (or a definitive rejection).
struct ChatOutgoingSubmissionPresentation: Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let attachmentIDs: [String]
    let behavior: String?
    let transportActive: Bool

    init(snapshot: ComposerSubmissionSnapshot, transportActive: Bool) {
        id = snapshot.presentationID
        text = snapshot.outgoingText
        attachmentIDs = snapshot.attachmentIDs
        behavior = snapshot.behavior
        self.transportActive = transportActive
    }

    var statusTitle: String? {
        switch behavior {
        case "steer": return "Steering next"
        case "followUp": return "Follow-up pending"
        default: return nil
        }
    }
}

/// Authoritative prompt admission that has not reached canonical JSONL yet.
/// Unlike the composer-owned outgoing row, this survives chat re-navigation
/// because it is reconstructed from the Gateway session snapshot.
struct ChatPendingPromptPresentation: Equatable, Identifiable, Sendable {
    let id: String
    let createdAt: String?
    let text: String
    let behavior: SessionSnapshot.QueuedMessage.Behavior?
    let attachmentCount: Int
    let photoCount: Int?
    let fileAttachmentCount: Int?
    let isCompacting: Bool

    init(snapshot: SessionSnapshot.PendingPrompt, isCompacting: Bool) {
        id = snapshot.id
        createdAt = snapshot.createdAt
        text = snapshot.text
        behavior = snapshot.behavior
        attachmentCount = snapshot.attachmentCount
        photoCount = snapshot.photoCount
        fileAttachmentCount = snapshot.fileAttachmentCount
        self.isCompacting = isCompacting
    }

    var statusTitle: String {
        if isCompacting {
            switch behavior {
            case .steer: return "Steering after compaction"
            case .followUp: return "Follow-up after compaction"
            case nil: return "Sending after compaction"
            }
        }
        switch behavior {
        case .steer: return "Steering next"
        case .followUp: return "Follow-up pending"
        case nil: return "Sending"
        }
    }
}

/// The single ephemeral runtime row shown after the canonical transcript while
/// an active session reports visible working state.
struct ChatRuntimeWorkingPresentation: Equatable {
    let message: String
    let retryMessage: String?
    let phase: SessionPhase
    let usesAmbientBottomIndicator: Bool

    init?(phase: SessionPhase, working: ExtensionSemanticState.Working, retry: RetryState?) {
        guard phase.isActive, working.visible else { return nil }
        self.phase = phase
        message = working.message ?? Self.defaultMessage(for: phase)
        retryMessage = retry.map {
            "Attempt \($0.attempt)\($0.maxAttempts.map { " of \($0)" } ?? "")"
        }
        usesAmbientBottomIndicator = phase == .running
            && working.message == nil
            && retry == nil
    }

    private static func defaultMessage(for phase: SessionPhase) -> String {
        switch phase {
        case .running: "Tron is working"
        case .compacting: "Compacting context"
        case .retrying: "Retrying provider"
        case .interrupted, .idle: ""
        }
    }
}

struct ChatTranscriptGeometry: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    /// Native visible content edges in the scroll content coordinate space.
    /// Synthetic tests may omit them and use the legacy-field fallback.
    let visibleTopY: CGFloat?
    let visibleBottomY: CGFloat?

    init(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat = 0,
        visibleTopY: CGFloat? = nil,
        visibleBottomY: CGFloat? = nil
    ) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.bottomInset = bottomInset
        self.visibleTopY = visibleTopY
        self.visibleBottomY = visibleBottomY
    }

    init(_ geometry: ScrollGeometry) {
        self.init(
            offsetY: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            bottomInset: geometry.contentInsets.bottom,
            visibleTopY: geometry.visibleRect.minY,
            visibleBottomY: geometry.visibleRect.maxY
        )
    }

    static let zero = ChatTranscriptGeometry(offsetY: 0, contentHeight: 0, containerHeight: 0)
    var isValid: Bool { contentHeight > 0 && containerHeight > 0 }
    var distanceFromBottom: CGFloat {
        // `visibleRect` is SwiftUI's native, atomically derived content-space
        // viewport. Do not reconstruct it from offset/container/inset fields,
        // which can settle in different LazyVStack/keyboard layout frames.
        let rawDistance = if let visibleBottomY {
            contentHeight + bottomInset - visibleBottomY
        } else {
            contentHeight + bottomInset - offsetY - containerHeight
        }
        guard rawDistance.isFinite else { return .greatestFiniteMagnitude }
        return max(0, rawDistance)
    }
    static let catchUpDistance: CGFloat = 16
    var isAtBottom: Bool { isValid && distanceFromBottom <= 80 }
    var isAtExactBottom: Bool { isValid && distanceFromBottom <= 2 }
    /// Physical scroll settling commonly stops a few points above the computed
    /// edge because content insets and pixel rounding update in separate frames.
    /// This tighter-than-"near bottom" boundary is user-equivalent to reaching
    /// the tail and is used to dismiss catch-up without requiring a tap.
    var isAtCatchUpBoundary: Bool { isValid && distanceFromBottom <= Self.catchUpDistance }

    /// Opening placement must reject a transient native offset beyond an
    /// overflowing content edge. `distanceFromBottom` intentionally clamps
    /// negative values for ordinary scrolling, so it cannot distinguish that
    /// overshoot from a real tail boundary on its own.
    var isPlausibleOpeningViewport: Bool {
        guard isValid else { return false }
        let contentBottom = contentHeight + bottomInset
        guard contentBottom.isFinite, offsetY.isFinite else { return false }
        if contentBottom <= containerHeight + 2 {
            // Undersized transcripts must be top aligned; clamped bottom distance
            // would otherwise accept a transient positive or negative overshoot.
            if let visibleTopY {
                return visibleTopY.isFinite && abs(visibleTopY) <= 2
            }
            return abs(offsetY) <= 2
        }
        if let visibleBottomY {
            // Native visible geometry is atomically derived and already accounts
            // for top/safe-area scroll insets that are absent from `offsetY`.
            return visibleBottomY.isFinite && visibleBottomY <= contentBottom + 2
        }
        let maximumOffset = contentBottom - containerHeight
        return offsetY <= maximumOffset + 2
    }

    func hasViewportChange(from previous: Self) -> Bool {
        abs(containerHeight - previous.containerHeight) > 0.5
            || abs(bottomInset - previous.bottomInset) > 0.5
    }
}

enum ChatOpenPresentationPhase: Equatable {
    case opening
    case positioning
    case ready
    case failed(String)
}

struct ChatOpenPresentationState: Equatable {
    let sessionID: String
    private(set) var epoch: Int = 0
    private(set) var phase: ChatOpenPresentationPhase = .opening

    mutating func begin(retainingVisiblePresentation: Bool = false) -> Int {
        epoch &+= 1
        phase = retainingVisiblePresentation ? .ready : .opening
        return epoch
    }

    mutating func installAuthoritativeBaseline(sessionID: String, epoch: Int) -> Bool {
        guard sessionID == self.sessionID, epoch == self.epoch, phase == .opening else { return false }
        // Keep the opaque opening surface mounted while the exact physical tail
        // is positioned. Authoritative installation alone is not proof that a
        // lazy transcript has a valid visible viewport.
        phase = .positioning
        return true
    }

    mutating func installPositionedViewport(sessionID: String, epoch: Int) -> Bool {
        guard sessionID == self.sessionID, epoch == self.epoch, phase == .positioning else { return false }
        phase = .ready
        return true
    }

    mutating func fail(sessionID: String, epoch: Int, message: String) -> Bool {
        guard sessionID == self.sessionID, epoch == self.epoch else { return false }
        phase = .failed(message)
        return true
    }
}

struct ChatTranscriptPageRequest: Equatable {
    static let maximumItemCount = 512

    let sessionID: String
    let presentationGeneration: Int
    let runtimeGeneration: String
    let before: Int
    let expectedTotal: Int
    let expectedNextEntryID: String?

    func canInstall(
        sessionID: String,
        presentationGeneration: Int,
        runtimeGeneration: String,
        transcriptStart: Int?,
        transcriptTotal: Int?,
        firstTranscriptID: String?
    ) -> Bool {
        self.sessionID == sessionID
            && self.presentationGeneration == presentationGeneration
            && self.runtimeGeneration == runtimeGeneration
            && transcriptStart == before
            && transcriptTotal == expectedTotal
            && firstTranscriptID == expectedNextEntryID
    }

    func canInstallPage(
        start: Int,
        end: Int,
        total: Int,
        itemCount: Int,
        visibleItemCount: Int
    ) -> Bool {
        end == before
            && start >= 0
            && start <= end
            && itemCount == end - start
            && itemCount <= Self.maximumItemCount
            && total == expectedTotal
            && total >= before
            && total - before == visibleItemCount
    }
}

struct ChatStreamingResponseSignature: Equatable {
    let itemID: String
    let parts: [ChatMessagePart]
    let errorMessage: String?

    init?(_ item: TranscriptItem?) {
        guard let item else { return nil }
        let visibleParts = ChatTranscriptPresentation.messageParts(in: item).filter { part in
            guard case .content(let content) = part else { return true }
            return content.type != .toolCall
        }
        let visibleError = (item.errorMessage ?? "").isEmpty ? nil : item.errorMessage
        guard !visibleParts.isEmpty || visibleError != nil else { return nil }
        itemID = item.id
        parts = visibleParts
        errorMessage = visibleError
    }
}

struct ChatResponseState: Equatable {
    let sessionID: String
    let canonicalEntryCount: Int
    let tailEntryID: String?
    let streaming: ChatStreamingResponseSignature?

    init(snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        canonicalEntryCount = snapshot.transcriptTotal ?? snapshot.transcript.count
        tailEntryID = snapshot.transcript.last?.id
        streaming = ChatStreamingResponseSignature(snapshot.streaming)
    }
}

/// Heavy protocol values are owned separately from the timeline descriptor
/// spine and are combined only when an installed transcript resolves a detail.
struct ChatToolPayload: Hashable, Sendable {
    let request: JSONValue?
    let response: JSONValue?
    let content: String
    let fallbackContent: JSONValue?
}

struct ChatToolDescriptor: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let error: Bool
    let startedAt: String?
    let completedAt: String?
    let durationMs: Int?
    let lastProgressAt: String?
    let progressSequence: Int?
    let outputTruncated: Bool
    let extensionOrigin: ExtensionToolOrigin?

    init(_ tool: ChatToolPresentation) {
        id = tool.id
        title = tool.title
        subtitle = tool.subtitle
        error = tool.error
        startedAt = tool.startedAt
        completedAt = tool.completedAt
        durationMs = tool.durationMs
        lastProgressAt = tool.lastProgressAt
        progressSequence = tool.progressSequence
        outputTruncated = tool.outputTruncated
        extensionOrigin = tool.extensionOrigin
    }

    var isRunning: Bool { subtitle == "Running" || subtitle == "Invocation" }

    func elapsedMilliseconds(at date: Date = .now) -> Int? {
        if isRunning, let durationMs {
            return max(0, durationMs)
        }
        guard let start = ToolTiming.date(startedAt) else {
            return durationMs.map { max(0, $0) }
        }
        if isRunning {
            return ToolTiming.milliseconds(from: start, to: date)
        }
        return ToolTiming.resolvedDuration(
            startedAt: startedAt,
            completedAt: completedAt,
            fallback: durationMs
        )
    }
}

struct ChatToolPayloadIndex: Hashable, Sendable {
    private let values: [String: ChatToolPayload]

    init(_ values: [String: ChatToolPayload] = [:]) {
        self.values = values
    }

    var callIDs: Set<String> { Set(values.keys) }
    var count: Int { values.count }

    func payload(for callID: String) -> ChatToolPayload? { values[callID] }

    func resolving(_ descriptor: ChatToolDescriptor) -> ChatToolPresentation? {
        guard let payload = values[descriptor.id] else { return nil }
        return ChatToolPresentation(descriptor: descriptor, payload: payload)
    }

    func replacing(_ replacements: [String: ChatToolPayload]) -> Self {
        var updated = values
        for (callID, payload) in replacements { updated[callID] = payload }
        return Self(updated)
    }
}

struct ChatToolPresentation: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let request: JSONValue?
    let response: JSONValue?
    let content: String
    let fallbackContent: JSONValue?
    let error: Bool
    let startedAt: String?
    let completedAt: String?
    let durationMs: Int?
    let lastProgressAt: String?
    let progressSequence: Int?
    let outputTruncated: Bool
    let extensionOrigin: ExtensionToolOrigin?

    init(
        id: String,
        title: String,
        subtitle: String,
        request: JSONValue?,
        response: JSONValue?,
        content: String,
        fallbackContent: JSONValue?,
        error: Bool,
        startedAt: String?,
        completedAt: String?,
        durationMs: Int?,
        lastProgressAt: String?,
        progressSequence: Int?,
        outputTruncated: Bool = false,
        extensionOrigin: ExtensionToolOrigin? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.request = request
        self.response = response
        self.content = content
        self.fallbackContent = fallbackContent
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.lastProgressAt = lastProgressAt
        self.progressSequence = progressSequence
        self.outputTruncated = outputTruncated || response?.hasToolOutputTruncationMetadata == true
        self.extensionOrigin = extensionOrigin
    }

    init(descriptor: ChatToolDescriptor, payload: ChatToolPayload) {
        id = descriptor.id
        title = descriptor.title
        subtitle = descriptor.subtitle
        request = payload.request
        response = payload.response
        content = payload.content
        fallbackContent = payload.fallbackContent
        error = descriptor.error
        startedAt = descriptor.startedAt
        completedAt = descriptor.completedAt
        durationMs = descriptor.durationMs
        lastProgressAt = descriptor.lastProgressAt
        progressSequence = descriptor.progressSequence
        outputTruncated = descriptor.outputTruncated
        extensionOrigin = descriptor.extensionOrigin
    }

    var descriptor: ChatToolDescriptor { ChatToolDescriptor(self) }
    var payload: ChatToolPayload {
        ChatToolPayload(
            request: request,
            response: response,
            content: content,
            fallbackContent: fallbackContent
        )
    }

    var isRunning: Bool { subtitle == "Running" || subtitle == "Invocation" }

    func elapsedMilliseconds(at date: Date = .now) -> Int? {
        if isRunning, let durationMs {
            return max(0, durationMs)
        }
        guard let start = ToolTiming.date(startedAt) else {
            return durationMs.map { max(0, $0) }
        }
        if isRunning {
            return ToolTiming.milliseconds(from: start, to: date)
        }
        return ToolTiming.resolvedDuration(
            startedAt: startedAt,
            completedAt: completedAt,
            fallback: durationMs
        )
    }

}

private extension JSONValue {
    var hasToolOutputTruncationMetadata: Bool {
        guard let object = objectValue else { return false }
        if object["truncation"]?.objectValue?["truncated"]?.boolValue == true { return true }
        return object["details"]?.objectValue?["truncation"]?.objectValue?["truncated"]?.boolValue == true
    }
}

/// Runtime timestamps are authoritative for live/current-Gateway calls. Pi JSONL
/// does not yet persist execution timing, so older canonical calls use their call
/// and result entry timestamps as a conservative observed interval.
enum ToolTiming {
    static func date(_ value: String?) -> Date? {
        value.flatMap(GatewayTimestamp.parse)
    }

    static func intervalMilliseconds(start: String?, end: String?) -> Int? {
        guard let start = date(start), let end = date(end) else { return nil }
        return milliseconds(from: start, to: end)
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        let interval = end.timeIntervalSince(start)
        guard interval.isFinite else { return 0 }
        let milliseconds = interval * 1_000
        guard milliseconds.isFinite else { return interval.sign == .minus ? 0 : Int.max }
        let rounded = milliseconds.rounded()
        guard rounded <= Double(Int.max) else { return Int.max }
        guard rounded >= Double(Int.min) else { return 0 }
        return max(0, Int(rounded))
    }

    /// Runtime duration is authoritative when supplied by the Gateway because
    /// it is measured from the tool callback with a monotonic clock. Timestamp
    /// subtraction is only the compatibility fallback for older canonical
    /// history that has no retained execution metadata.
    static func resolvedDuration(
        startedAt: String?,
        completedAt: String?,
        fallback: Int?
    ) -> Int? {
        if let fallback { return max(0, fallback) }
        return intervalMilliseconds(start: startedAt, end: completedAt)
    }

    static func format(milliseconds: Int) -> String {
        let milliseconds = max(0, milliseconds)
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        if milliseconds < 60_000 { return String(format: "%.1fs", Double(milliseconds) / 1_000) }
        let totalSeconds = milliseconds / 1_000
        if totalSeconds < 3_600 { return "\(totalSeconds / 60)m \(totalSeconds % 60)s" }
        return "\(totalSeconds / 3_600)h \((totalSeconds % 3_600) / 60)m"
    }

    static func observedDuration(callTimestamp: String, result: TranscriptItem) -> Int? {
        resolvedDuration(
            startedAt: result.startedAt ?? callTimestamp,
            completedAt: result.completedAt ?? result.timestamp,
            fallback: result.durationMs
        )
    }
}

enum ChatTokenCountPresentation {
    static func compact(_ count: Int) -> String {
        let count = max(0, count)
        guard count >= 1_000 else { return String(count) }

        let thousands = Double(count) / 1_000
        let precision = thousands >= 100 ? 0 : 1
        var value = String(format: "%.*f", precision, thousands)
        if value.hasSuffix(".0") { value.removeLast(2) }
        return "\(value)K"
    }

    static func beforeCompaction(_ count: Int) -> String {
        "\(compact(count)) \(count == 1 ? "token" : "tokens") before compaction"
    }
}

enum ChatNotificationTone: Hashable, Sendable {
    case accent
    case information
    case warning
    case error
    case neutral
}

enum ChatNotificationMaterial: Hashable, Sendable {
    case flat
    case glass
}

struct ChatNotificationPresentation: Hashable, Identifiable, Sendable {
    let id: String
    let semanticID: String?
    let icon: String
    let title: String
    let detail: String?
    let body: String?
    let tone: ChatNotificationTone
    let material: ChatNotificationMaterial

    var hasDetailSheet: Bool { material == .glass && body?.isEmpty == false }
    var showsProgress: Bool {
        semanticID == nil && (
            id == "runtime-working" || id.hasPrefix("notification-compaction-slot-")
        )
    }

    static func canonical(
        _ item: TranscriptItem,
        globalOrdinal: Int?
    ) -> ChatNotificationPresentation? {
        let summaryBody = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let admittedSummary = summaryBody?.isEmpty == false ? summaryBody : nil
        switch item.kind {
        case .compaction:
            return ChatNotificationPresentation(
                id: globalOrdinal.map { "notification-compaction-slot-\($0)" }
                    ?? "notification-compaction-\(item.id)",
                semanticID: item.id,
                icon: "arrow.down.right.and.arrow.up.left",
                title: "Context compacted",
                detail: item.tokensBefore.map(ChatTokenCountPresentation.beforeCompaction),
                body: admittedSummary,
                tone: .accent,
                material: admittedSummary == nil ? .flat : .glass
            )
        case .branchSummary:
            return ChatNotificationPresentation(
                id: "notification-\(item.id)", semanticID: item.id,
                icon: "arrow.triangle.branch", title: "Branch summary",
                detail: nil, body: admittedSummary, tone: .accent,
                material: admittedSummary == nil ? .flat : .glass
            )
        case .modelChange:
            return ChatNotificationPresentation(
                id: "notification-\(item.id)", semanticID: item.id,
                icon: "cpu", title: "Model changed",
                detail: item.modelRef?.displayDescription ?? "Changed",
                body: nil, tone: .accent, material: .flat
            )
        case .thinkingChange:
            return ChatNotificationPresentation(
                id: "notification-\(item.id)", semanticID: item.id,
                icon: "brain", title: "Thinking changed",
                detail: item.level?.capitalized ?? "Changed",
                body: nil, tone: .accent, material: .flat
            )
        case .label:
            return ChatNotificationPresentation(
                id: "notification-\(item.id)", semanticID: item.id,
                icon: "bookmark",
                title: item.label.map { "Bookmark: \($0)" } ?? "Bookmark removed",
                detail: nil, body: nil, tone: .neutral, material: .flat
            )
        case .message, .bash, .customMessage, .customEntry:
            return nil
        }
    }

    static func runtime(in snapshot: SessionSnapshot) -> [ChatNotificationPresentation] {
        var values: [ChatNotificationPresentation] = []
        if snapshot.compactionQueued == true {
            values.append(ChatNotificationPresentation(
                id: "runtime-compaction-queued",
                semanticID: nil,
                icon: "arrow.down.right.and.arrow.up.left",
                title: "Compaction queued",
                detail: "After current work",
                body: nil,
                tone: .accent,
                material: .flat
            ))
        }
        if let working = ChatRuntimeWorkingPresentation(
            phase: snapshot.phase,
            working: snapshot.extensionPresentation.semanticState.working,
            retry: snapshot.retry
        ), !working.usesAmbientBottomIndicator {
            let exactNextOrdinal: Int? = {
                guard snapshot.phase == .compacting,
                      let start = snapshot.transcriptStart,
                      let total = snapshot.transcriptTotal,
                      start >= 0, total >= start,
                      total - start == snapshot.transcript.count else { return nil }
                return total
            }()
            values.append(ChatNotificationPresentation(
                id: exactNextOrdinal.map { "notification-compaction-slot-\($0)" }
                    ?? "runtime-working",
                semanticID: nil,
                icon: working.phase == .compacting
                    ? "arrow.down.right.and.arrow.up.left"
                    : working.phase == .retrying ? "arrow.clockwise" : "sparkles",
                title: working.message,
                detail: working.retryMessage,
                body: nil,
                tone: working.phase == .retrying ? .warning : .accent,
                material: .flat
            ))
        }
        // Extension statuses are presented by the composer activity pill, not
        // as transcript rows. This keeps transient extension chrome out of
        // canonical conversation scrolling.
        return values
    }
}

enum ChatToolInvocationOrdering {
    /// Detail surfaces intentionally reverse the canonical invocation order:
    /// the newest tool is always the first row. If every row has usable
    /// invocation metadata, timestamps determine the order. Otherwise the
    /// canonical array order is used as one consistent fallback; mixing those
    /// policies pair-by-pair would produce an unstable, non-transitive sort.
    static func reverseChronological(_ tools: [ChatToolDescriptor]) -> [ChatToolDescriptor] {
        reverseChronological(tools, descriptor: { $0 })
    }

    static func reverseChronological(_ tools: [ChatToolPresentation]) -> [ChatToolPresentation] {
        reverseChronological(tools, descriptor: \.descriptor)
    }

    private static func reverseChronological<Element>(
        _ tools: [Element],
        descriptor: (Element) -> ChatToolDescriptor
    ) -> [Element] {
        let indexed = tools.enumerated()
        let dates = indexed.map { invocationDate(for: descriptor($0.element)) }
        let allHaveDates = dates.allSatisfy { $0 != nil }

        return indexed.sorted { left, right in
            if allHaveDates,
               let leftDate = dates[left.offset],
               let rightDate = dates[right.offset],
               leftDate != rightDate {
                return leftDate > rightDate
            }
            return left.offset > right.offset
        }.map(\.element)
    }

    private static func invocationDate(for tool: ChatToolDescriptor) -> Date? {
        ToolTiming.date(tool.startedAt)
            ?? ToolTiming.date(tool.completedAt)
            ?? ToolTiming.date(tool.lastProgressAt)
    }
}

struct ChatToolRunPresentation: Hashable, Identifiable, Sendable {
    let tools: [ChatToolDescriptor]
    let anchorID: String

    init(tools: [ChatToolDescriptor], anchorID: String? = nil) {
        self.tools = tools
        // Callers provide canonical content order or the runtime's monotonic
        // ordinal order. Opaque call IDs are not sortable order keys.
        self.anchorID = anchorID ?? tools.first?.id ?? "empty"
    }

    init(tools: [ChatToolPresentation], anchorID: String? = nil) {
        self.init(tools: tools.map(\.descriptor), anchorID: anchorID)
    }


    var id: String { "tool-run-" + anchorID }
    var reverseChronologicalTools: [ChatToolDescriptor] {
        ChatToolInvocationOrdering.reverseChronological(tools)
    }
    var isExtensionActivity: Bool { !tools.isEmpty && tools.allSatisfy { $0.extensionOrigin != nil } }
    var isRunning: Bool { tools.contains(where: \.isRunning) }
    var failureCount: Int { tools.filter(\.error).count }
    var title: String {
        if isExtensionActivity { return isRunning ? "Extension activity" : "Extension activity complete" }
        return "\(isRunning ? "Using" : "Used") \(tools.count) \(tools.count == 1 ? "tool" : "tools")"
    }
    var status: String? {
        if failureCount > 0 { return "\(failureCount) failed" }
        return isRunning ? "in progress" : nil
    }
    /// Accumulated tool time is the sum of each invocation, rather than the
    /// wall-clock span of the run. This remains correct when tools overlap and
    /// keeps the Used tools detail surface consistent with its individual rows.
    func elapsedMilliseconds(at date: Date = .now) -> Int? {
        let values = tools.compactMap { $0.elapsedMilliseconds(at: date) }
        guard !values.isEmpty else { return nil }
        return values.reduce(into: 0) { total, value in
            total = total > Int.max - value ? Int.max : total + value
        }
    }
}

struct ChatThinkingSegment: Hashable, Identifiable, Sendable {
    let id: String
    let text: String
}

struct ChatThinkingRun: Hashable, Identifiable, Sendable {
    /// The contiguous-run ordinal is stable when bounded live frames drop
    /// leading thinking parts. Word-level reveal remains row-local state.
    let id: String
    let segments: [ChatThinkingSegment]
}

enum ChatTranscriptRowIdentity {
    static func assistantMessage(_ item: TranscriptItem) -> String {
        item.role == .assistant ? item.presentationId : item.id
    }

    static func messageSlice(
        _ item: TranscriptItem,
        parts: [ChatMessagePart],
        slice: Int
    ) -> String {
        let first = assistantMessage(item)
        if slice == 0 { return first }
        if let part = parts.first { return "\(first)-slice-\(part.id)" }
        return "\(first)-footer-\(slice)"
    }
}

enum ChatMessagePart: Hashable, Identifiable, Sendable {
    case content(ContentPart)
    case thinking(ChatThinkingRun)

    var id: String {
        switch self {
        case .content(let part): "content-\(part.ordinal)"
        case .thinking(let run): "thinking-\(run.id)"
        }
    }
}

struct ChatMessagePresentation: Hashable, Identifiable, Sendable {
    let id: String
    let semanticID: String
    let item: TranscriptItem
    let parts: [ChatMessagePart]
    let streaming: Bool
    let showsFooter: Bool

}

enum ChatTranscriptRenderItem: Hashable, Identifiable, Sendable {
    case transcript(TranscriptItem)
    case message(ChatMessagePresentation)
    case toolRun(ChatToolRunPresentation)
    case notification(ChatNotificationPresentation)

    var id: String {
        switch self {
        case .transcript(let item): item.id
        case .message(let message): message.id
        case .toolRun(let run): run.id
        case .notification(let notification): notification.id
        }
    }
}

/// A flat immutable row spine. Sparse tool updates share the assembly-produced
/// base and replace only affected indexes; an assembly always starts a fresh
/// base, so overlays never form a chain.
struct ChatTranscriptItems: RandomAccessCollection, Hashable, Sendable {
    typealias Index = Int

    private let canonicalBase: [ChatTranscriptRenderItem]
    private let canonicalOverrides: [Int: ChatTranscriptRenderItem]
    let live: [ChatTranscriptRenderItem]

    init(canonical: [ChatTranscriptRenderItem], live: [ChatTranscriptRenderItem] = []) {
        canonicalBase = canonical
        canonicalOverrides = [:]
        self.live = live
    }

    private init(
        canonicalBase: [ChatTranscriptRenderItem],
        canonicalOverrides: [Int: ChatTranscriptRenderItem],
        live: [ChatTranscriptRenderItem]
    ) {
        self.canonicalBase = canonicalBase
        self.canonicalOverrides = canonicalOverrides
        self.live = live
    }

    /// Compatibility access for the few cold-path callers that need an Array.
    /// Render and validation paths use the collection directly.
    var canonical: [ChatTranscriptRenderItem] {
        guard !canonicalOverrides.isEmpty else { return canonicalBase }
        var result = canonicalBase
        for (index, item) in canonicalOverrides { result[index] = item }
        return result
    }

    var canonicalCount: Int { canonicalBase.count }
    var sparseOverrideCount: Int { canonicalOverrides.count }
    var startIndex: Int { 0 }
    var endIndex: Int { canonicalBase.count + live.count }

    subscript(position: Int) -> ChatTranscriptRenderItem {
        precondition(indices.contains(position))
        if position < canonicalBase.count {
            return canonicalOverrides[position] ?? canonicalBase[position]
        }
        return live[position - canonicalBase.count]
    }

    func replacingCanonical(
        _ replacements: [Int: ChatTranscriptRenderItem]
    ) -> ChatTranscriptItems {
        guard !replacements.isEmpty else { return self }
        var overrides = canonicalOverrides
        for (index, item) in replacements {
            precondition(canonicalBase.indices.contains(index))
            if item == canonicalBase[index] {
                overrides.removeValue(forKey: index)
            } else {
                overrides[index] = item
            }
        }
        return ChatTranscriptItems(
            canonicalBase: canonicalBase,
            canonicalOverrides: overrides,
            live: live
        )
    }

    func replacingLive(_ live: [ChatTranscriptRenderItem]) -> ChatTranscriptItems {
        ChatTranscriptItems(
            canonicalBase: canonicalBase,
            canonicalOverrides: canonicalOverrides,
            live: live
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.count == rhs.count && lhs.elementsEqual(rhs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for item in self { hasher.combine(item) }
    }
}

struct ChatSemanticIndex: Hashable, Sendable {
    let canonical: [String: String]
    let live: [String: String]

    init(canonical: [String: String], live: [String: String] = [:]) {
        self.canonical = canonical
        self.live = live
    }

    subscript(key: String) -> String? { live[key] ?? canonical[key] }

    func allKeysSatisfy(_ predicate: (String) -> Bool) -> Bool {
        canonical.keys.allSatisfy(predicate) && live.keys.allSatisfy(predicate)
    }

    func allValuesSatisfy(_ predicate: (String) -> Bool) -> Bool {
        canonical.values.allSatisfy(predicate) && live.values.allSatisfy(predicate)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.canonical == rhs.canonical, lhs.live == rhs.live { return true }
        let keys = Set(lhs.canonical.keys)
            .union(lhs.live.keys)
            .union(rhs.canonical.keys)
            .union(rhs.live.keys)
        return keys.allSatisfy { lhs[$0] == rhs[$0] }
    }

    func hash(into hasher: inout Hasher) {
        let keys = Set(canonical.keys).union(live.keys).sorted()
        hasher.combine(keys.count)
        for key in keys {
            hasher.combine(key)
            hasher.combine(self[key])
        }
    }
}

struct ChatTranscriptIDs: RandomAccessCollection, Hashable, Sendable {
    typealias Index = Int

    private final class CanonicalStorage: @unchecked Sendable {
        let values: [String]
        let identityDigest: UInt64

        init(_ values: [String]) {
            self.values = values
            identityDigest = ChatTranscriptIDs.digest(values)
        }
    }

    private let canonicalStorage: CanonicalStorage
    let live: [String]

    init(canonical: [String], live: [String]) {
        canonicalStorage = CanonicalStorage(canonical)
        self.live = live
    }

    private init(canonicalStorage: CanonicalStorage, live: [String]) {
        self.canonicalStorage = canonicalStorage
        self.live = live
    }

    var canonical: [String] { canonicalStorage.values }
    var startIndex: Int { 0 }
    var endIndex: Int { canonicalStorage.values.count + live.count }

    subscript(position: Int) -> String {
        precondition(indices.contains(position))
        return position < canonicalStorage.values.count
            ? canonicalStorage.values[position]
            : live[position - canonicalStorage.values.count]
    }

    func replacingLive(_ live: [String]) -> ChatTranscriptIDs {
        ChatTranscriptIDs(canonicalStorage: canonicalStorage, live: live)
    }

    func sharesCanonicalStorage(with other: ChatTranscriptIDs) -> Bool {
        canonicalStorage === other.canonicalStorage
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.canonicalStorage === rhs.canonicalStorage {
            return lhs.live == rhs.live
        }
        return lhs.count == rhs.count && lhs.elementsEqual(rhs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        hasher.combine(Self.digest(live, startingAt: canonicalStorage.identityDigest))
    }

    private static func digest(
        _ values: [String],
        startingAt initial: UInt64 = 14_695_981_039_346_656_037
    ) -> UInt64 {
        var result = initial
        for value in values {
            for byte in value.utf8 {
                result ^= UInt64(byte)
                result &*= 1_099_511_628_211
            }
            result ^= 0xff
            result &*= 1_099_511_628_211
        }
        return result
    }
}

func == (lhs: ChatTranscriptIDs, rhs: [String]) -> Bool {
    lhs.count == rhs.count && lhs.elementsEqual(rhs)
}

func == (lhs: [String], rhs: ChatTranscriptIDs) -> Bool { rhs == lhs }

struct ChatTranscriptTimeline: Hashable, Sendable {
    let items: ChatTranscriptItems
    let preferredSemanticIDByRenderedID: ChatSemanticIndex
    let renderedIDBySemanticID: ChatSemanticIndex
    private let renderedIDs: ChatTranscriptIDs
    private let canonicalRenderedIDSet: Set<String>
    private let liveRenderedIDSet: Set<String>
    private let internallyConsistent: Bool

    init(
        items: ChatTranscriptItems,
        preferredSemanticIDByRenderedID: ChatSemanticIndex,
        renderedIDBySemanticID: ChatSemanticIndex
    ) {
        self.items = items
        self.preferredSemanticIDByRenderedID = preferredSemanticIDByRenderedID
        self.renderedIDBySemanticID = renderedIDBySemanticID
        let canonicalIDs = (0..<items.canonicalCount).map { items[$0].id }
        let liveIDs = items.live.map(\.id)
        let ids = ChatTranscriptIDs(canonical: canonicalIDs, live: liveIDs)
        let canonicalIDSet = Set(canonicalIDs)
        let liveIDSet = Set(liveIDs)
        renderedIDs = ids
        canonicalRenderedIDSet = canonicalIDSet
        liveRenderedIDSet = liveIDSet
        let containsID = { canonicalIDSet.contains($0) || liveIDSet.contains($0) }
        internallyConsistent = canonicalIDSet.count == canonicalIDs.count
            && liveIDSet.count == liveIDs.count
            && canonicalIDSet.isDisjoint(with: liveIDSet)
            && preferredSemanticIDByRenderedID.allKeysSatisfy(containsID)
            && renderedIDBySemanticID.allValuesSatisfy(containsID)
    }

    private init(
        items: ChatTranscriptItems,
        preferredSemanticIDByRenderedID: ChatSemanticIndex,
        renderedIDBySemanticID: ChatSemanticIndex,
        renderedIDs: ChatTranscriptIDs,
        canonicalRenderedIDSet: Set<String>,
        liveRenderedIDSet: Set<String>,
        internallyConsistent: Bool
    ) {
        self.items = items
        self.preferredSemanticIDByRenderedID = preferredSemanticIDByRenderedID
        self.renderedIDBySemanticID = renderedIDBySemanticID
        self.renderedIDs = renderedIDs
        self.canonicalRenderedIDSet = canonicalRenderedIDSet
        self.liveRenderedIDSet = liveRenderedIDSet
        self.internallyConsistent = internallyConsistent
    }

    var ids: ChatTranscriptIDs { renderedIDs }
    var isInternallyConsistent: Bool { internallyConsistent }
    func sharesCanonicalIdentitySpine(with other: ChatTranscriptTimeline) -> Bool {
        renderedIDs.sharesCanonicalStorage(with: other.renderedIDs)
    }
    func containsID(_ id: String) -> Bool {
        canonicalRenderedIDSet.contains(id) || liveRenderedIDSet.contains(id)
    }

    /// Sparse replacements are permitted only after the kernel proves every row
    /// identity unchanged, so the cached identity spine and semantic maps remain
    /// the exact canonical values rather than being rebuilt or guessed.
    func replacingCanonicalRows(
        _ replacements: [Int: ChatTranscriptRenderItem]
    ) -> ChatTranscriptTimeline {
        ChatTranscriptTimeline(
            items: items.replacingCanonical(replacements),
            preferredSemanticIDByRenderedID: preferredSemanticIDByRenderedID,
            renderedIDBySemanticID: renderedIDBySemanticID,
            renderedIDs: renderedIDs,
            canonicalRenderedIDSet: canonicalRenderedIDSet,
            liveRenderedIDSet: liveRenderedIDSet,
            internallyConsistent: internallyConsistent
        )
    }

    func appendingLive(_ live: ChatTranscriptTimeline) -> ChatTranscriptTimeline {
        precondition(live.items.canonicalCount == 0)
        let canonicalIDSet = canonicalRenderedIDSet
        // A reconnect can briefly project the just-persisted assistant both as
        // canonical history and as the retained live handoff. Canonical wins;
        // never publish two SwiftUI rows with the same presentation identity.
        let admitsLive = canonicalIDSet.isDisjoint(with: live.liveRenderedIDSet)
        let admittedLiveItems = admitsLive ? live.items.live : []
        let admittedLiveIDs = admitsLive ? live.renderedIDs.live : []
        let liveIDSet = admitsLive ? live.liveRenderedIDSet : []
        let ids = renderedIDs.replacingLive(admittedLiveIDs)
        let preferred = ChatSemanticIndex(
            canonical: preferredSemanticIDByRenderedID.canonical,
            live: admitsLive ? live.preferredSemanticIDByRenderedID.live : [:]
        )
        let reverse = ChatSemanticIndex(
            canonical: renderedIDBySemanticID.canonical,
            live: admitsLive ? live.renderedIDBySemanticID.live : [:]
        )
        return ChatTranscriptTimeline(
            items: items.replacingLive(admittedLiveItems),
            preferredSemanticIDByRenderedID: preferred,
            renderedIDBySemanticID: reverse,
            renderedIDs: ids,
            canonicalRenderedIDSet: canonicalIDSet,
            liveRenderedIDSet: liveIDSet,
            internallyConsistent: internallyConsistent && live.internallyConsistent
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items
            && lhs.preferredSemanticIDByRenderedID == rhs.preferredSemanticIDByRenderedID
            && lhs.renderedIDBySemanticID == rhs.renderedIDBySemanticID
    }

    func hash(into hasher: inout Hasher) {
        // Equality implies identical rendered identities. Hashing the cached
        // split spine keeps sparse/live publications shallow; content and maps
        // may legally collide and are still compared exactly by `==`.
        hasher.combine(renderedIDs)
    }
}

enum ChatToolbarTitleLayout {
    static let defaultContainerWidth: CGFloat = 402
    static let horizontalControlReservation: CGFloat = 152
    static let minimumWidth: CGFloat = 80
    static let maximumWidth: CGFloat = 360

    static func width(containerWidth: CGFloat) -> CGFloat {
        min(maximumWidth, max(minimumWidth, containerWidth - horizontalControlReservation))
    }
}

struct ChatAttachmentMenuIdentity: Hashable {
    let sessionID: String
    let actionsEnabled: Bool
}

struct ChatAttachmentMenuState: Hashable {
    let sessionID: String
    let phase: SessionPhase?
    let isTranscriptReady: Bool
    let isSending: Bool

    var actionsEnabled: Bool {
        ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: isTranscriptReady,
            phase: phase,
            isSending: isSending
        )
    }

    var identity: ChatAttachmentMenuIdentity {
        ChatAttachmentMenuIdentity(sessionID: sessionID, actionsEnabled: actionsEnabled)
    }
}

enum ChatAttachmentAvailabilityPolicy {
    static func actionsEnabled(
        isTranscriptReady: Bool,
        phase: SessionPhase?,
        isSending: Bool
    ) -> Bool {
        guard isTranscriptReady, phase != nil else { return false }
        // Uploads stage independently of prompt transport. Keep the attachment
        // menu enabled while a send is being acknowledged and throughout active
        // steering; otherwise SwiftUI dims the Menu label and blocks legitimate
        // staging even though no attachment mutation is in flight.
        return true
    }
}

enum ChatUnreadResponsePolicy {
    static func shouldMarkUnread(
        previous: ChatResponseState?,
        current: ChatResponseState,
        userScrolledAway: Bool
    ) -> Bool {
        guard let previous, previous.sessionID == current.sessionID, userScrolledAway else { return false }
        return previous.canonicalEntryCount != current.canonicalEntryCount
            || previous.tailEntryID != current.tailEntryID
            || previous.streaming != current.streaming
    }
}

/// Presentation-only filtering for Pi's canonical transcript. Configuration
/// entries before the first conversational entry describe session bootstrap
/// state and belong in Manage Session, not in the chat transcript. Later
/// configuration entries remain visible as compact change notifications.
enum ChatTranscriptPresentation {
    static func items(in snapshot: SessionSnapshot) -> [TranscriptItem] {
        ChatTranscriptProjectionKernel.visibleItems(in: snapshot)
    }

    /// The public cold oracle delegates to the one raw-fragment/global-assembler
    /// kernel. No view constructs or repairs a timeline independently.
    static func timeline(
        in snapshot: SessionSnapshot,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        workRecorder: ChatTranscriptProjectionWorkRecorder? = nil
    ) -> ChatTranscriptTimeline {
        ChatTranscriptProjectionKernel.cold(
            snapshot: snapshot,
            performanceSignposts: performanceSignposts,
            workRecorder: workRecorder
        ).timeline
    }

    /// The compatibility wrapper delegates suffix construction to the sole
    /// output-producing kernel.
    static func isolatedStreamingTimeline(_ item: TranscriptItem) -> ChatTranscriptTimeline? {
        ChatTranscriptProjectionKernel.isolatedStreamingTimeline(item)
    }

    static func attachmentParts(in item: TranscriptItem) -> [ContentPart] {
        (item.content ?? []).filter { $0.type == .image || $0.attachment != nil }
    }

    /// Coalesces only adjacent canonical thinking parts. The transcript remains
    /// authoritative; this projection simply turns line-oriented progress into
    /// one readable paragraph while preserving stable identities for animation.
    static func messageParts(in item: TranscriptItem) -> [ChatMessagePart] {
        var projected: [ChatMessagePart] = []
        var thinkingSegments: [ChatThinkingSegment] = []
        var thinkingRunID: String?

        func flushThinking() {
            guard let thinkingRunID, !thinkingSegments.isEmpty else { return }
            projected.append(.thinking(ChatThinkingRun(id: thinkingRunID, segments: thinkingSegments)))
            thinkingSegments.removeAll(keepingCapacity: true)
        }

        for part in item.content ?? [] {
            guard part.type == .thinking else {
                flushThinking()
                thinkingRunID = nil
                projected.append(.content(part))
                continue
            }
            guard let runOrdinal = part.thinkingRunOrdinal else { continue }
            let runID = "thinking-run-\(runOrdinal)"
            if let thinkingRunID, thinkingRunID != runID {
                flushThinking()
            }
            thinkingRunID = runID
            let segments = normalizedThinkingSegments(in: part)
            guard !segments.isEmpty else { continue }
            thinkingSegments.append(contentsOf: segments)
        }
        flushThinking()
        return projected
    }

    private static func normalizedThinkingSegments(in part: ContentPart) -> [ChatThinkingSegment] {
        (part.text ?? "")
            .split(whereSeparator: \.isNewline)
            .enumerated()
            .compactMap { lineIndex, line in
                let words = line.split(whereSeparator: \.isWhitespace)
                guard !words.isEmpty else { return nil }
                var text = words.joined(separator: " ")
                while text.last == "." || text.last == "…" { text.removeLast() }
                let presentation = text.isEmpty ? "…" : text + "…"
                return ChatThinkingSegment(id: "thinking-\(part.ordinal):line:\(lineIndex)", text: presentation)
            }
    }

}
