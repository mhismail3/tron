import Foundation
import TronMobileCore

struct SessionListWorkspaceGroup: Identifiable, Equatable {
    let path: String
    let name: String
    let profileID: String?
    let profileLabel: String?
    let sessions: [CatalogSession]

    var id: String {
        let workspaceID = path.isEmpty ? "__default_workspace__" : path
        return "\(profileID ?? "__unqualified__")|\(workspaceID)"
    }

    var displayName: String {
        guard let profileLabel, !profileLabel.isEmpty else { return name }
        return "\(profileLabel) · \(name)"
    }

    static func groups(from sessions: [CatalogSession]) -> [SessionListWorkspaceGroup] {
        var orderedKeys: [String] = []
        var sessionsByKey: [String: [CatalogSession]] = [:]

        for session in sessions {
            let key = "\(session.gatewayProfileID ?? "__unqualified__")|\(session.cwd)"
            if sessionsByKey[key] == nil {
                orderedKeys.append(key)
                sessionsByKey[key] = []
            }
            sessionsByKey[key, default: []].append(session)
        }

        return orderedKeys.compactMap { key in
            guard let sessions = sessionsByKey[key],
                  let first = sessions.first,
                  !sessions.isEmpty else { return nil }
            let path = first.cwd
            return SessionListWorkspaceGroup(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent.isEmpty
                    ? path
                    : URL(fileURLWithPath: path).lastPathComponent,
                profileID: first.gatewayProfileID,
                profileLabel: first.gatewayProfileLabel,
                sessions: sessions
            )
        }
    }
}

enum SessionListPaginationDirection: Equatable {
    case reveal
    case hide
}

enum SessionListPaginationPhase: Equatable {
    case layingOut
    case animatingRows
}

struct SessionListPaginationTransition: Equatable {
    let groupID: String
    let direction: SessionListPaginationDirection
    let stableCount: Int
    let renderedCount: Int
    let generation: Int
    var phase: SessionListPaginationPhase

    var affectedCount: Int {
        max(renderedCount - stableCount, 0)
    }
}

struct SessionListSessionExpansion: Equatable {
    private(set) var pageSize: Int

    private(set) var visibleCountsByGroupID: [String: Int] = [:]
    private var transitionByGroupID: [String: SessionListPaginationTransition] = [:]
    private var generationByGroupID: [String: Int] = [:]

    init(pageSize: Int = AppLocalBehaviorSettings.defaultDashboardChatsPerProject) {
        self.pageSize = AppLocalBehaviorSettings.boundedDashboardChatsPerProject(pageSize)
    }

    mutating func updatePageSize(_ value: Int) {
        let next = AppLocalBehaviorSettings.boundedDashboardChatsPerProject(value)
        guard next != pageSize else { return }
        pageSize = next
        visibleCountsByGroupID.removeAll()
        transitionByGroupID.removeAll()
    }

    func visibleCount(for groupID: String, totalCount: Int) -> Int {
        min(max(totalCount, 0), visibleCountsByGroupID[groupID] ?? pageSize)
    }

    func visibleSessions(in group: SessionListWorkspaceGroup) -> [CatalogSession] {
        Array(group.sessions.prefix(visibleCount(for: group.id, totalCount: group.sessions.count)))
    }

    func canViewMore(groupID: String, totalCount: Int) -> Bool {
        visibleCount(for: groupID, totalCount: totalCount) < totalCount
    }

    func canViewLess(groupID: String, totalCount: Int) -> Bool {
        totalCount > pageSize && visibleCount(for: groupID, totalCount: totalCount) > pageSize
    }

    mutating func showLess(groupID: String) {
        visibleCountsByGroupID.removeValue(forKey: groupID)
    }

    func transition(for groupID: String) -> SessionListPaginationTransition? {
        transitionByGroupID[groupID]
    }

    func isTransitioning(groupID: String) -> Bool {
        transitionByGroupID[groupID] != nil
    }

    func isRowVisible(groupID: String, index: Int) -> Bool {
        guard let transition = transitionByGroupID[groupID], index >= transition.stableCount else {
            return true
        }
        switch transition.direction {
        case .reveal:
            return transition.phase == .animatingRows
        case .hide:
            return false
        }
    }

    mutating func beginRevealMore(
        groupID: String,
        totalCount: Int
    ) -> SessionListPaginationTransition? {
        guard transitionByGroupID[groupID] == nil else { return nil }
        let currentCount = visibleCount(for: groupID, totalCount: totalCount)
        let nextCount = min(max(totalCount, 0), currentCount + pageSize)
        guard nextCount > currentCount else { return nil }

        let transition = makeTransition(
            groupID: groupID,
            direction: .reveal,
            stableCount: currentCount,
            renderedCount: nextCount,
            phase: .layingOut
        )
        visibleCountsByGroupID[groupID] = nextCount
        transitionByGroupID[groupID] = transition
        return transition
    }

    mutating func beginShowLess(
        groupID: String,
        totalCount: Int
    ) -> SessionListPaginationTransition? {
        guard transitionByGroupID[groupID] == nil else { return nil }
        let currentCount = visibleCount(for: groupID, totalCount: totalCount)
        let stableCount = min(pageSize, max(totalCount, 0))
        guard currentCount > stableCount else { return nil }

        let transition = makeTransition(
            groupID: groupID,
            direction: .hide,
            stableCount: stableCount,
            renderedCount: currentCount,
            phase: .animatingRows
        )
        transitionByGroupID[groupID] = transition
        return transition
    }

    @discardableResult
    mutating func beginRevealRows(_ expected: SessionListPaginationTransition) -> Bool {
        guard var current = currentTransition(matching: expected),
              current.direction == .reveal,
              current.phase == .layingOut else { return false }
        current.phase = .animatingRows
        transitionByGroupID[current.groupID] = current
        return true
    }

    @discardableResult
    mutating func finish(_ expected: SessionListPaginationTransition) -> Bool {
        guard let current = currentTransition(matching: expected) else { return false }
        if current.direction == .hide {
            showLess(groupID: current.groupID)
        }
        transitionByGroupID.removeValue(forKey: current.groupID)
        return true
    }

    mutating func reconcile(groupCounts: [String: Int]) {
        let validGroupIDs = Set(groupCounts.keys)
        transitionByGroupID.removeAll()
        visibleCountsByGroupID = visibleCountsByGroupID.reduce(into: [:]) { result, entry in
            guard let totalCount = groupCounts[entry.key], totalCount > pageSize else { return }
            result[entry.key] = min(max(entry.value, pageSize), totalCount)
        }
        generationByGroupID = generationByGroupID.filter { validGroupIDs.contains($0.key) }
    }

    private mutating func makeTransition(
        groupID: String,
        direction: SessionListPaginationDirection,
        stableCount: Int,
        renderedCount: Int,
        phase: SessionListPaginationPhase
    ) -> SessionListPaginationTransition {
        let generation = (generationByGroupID[groupID] ?? 0) + 1
        generationByGroupID[groupID] = generation
        return SessionListPaginationTransition(
            groupID: groupID,
            direction: direction,
            stableCount: stableCount,
            renderedCount: renderedCount,
            generation: generation,
            phase: phase
        )
    }

    private func currentTransition(
        matching expected: SessionListPaginationTransition
    ) -> SessionListPaginationTransition? {
        guard let current = transitionByGroupID[expected.groupID],
              current.generation == expected.generation else { return nil }
        return current
    }
}
