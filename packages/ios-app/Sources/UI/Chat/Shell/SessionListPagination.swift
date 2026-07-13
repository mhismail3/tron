import Foundation

/// Per-workspace pagination and transition state for dashboard session rows.
/// Rendering owns animation timing; this model owns only visible counts,
/// transition generations, and stale-completion rejection.
struct SessionListSessionExpansion: Equatable {
    static let pageSize = 10

    private(set) var visibleCountsByGroupId: [String: Int] = [:]
    private var transitionByGroupId: [String: SessionListPaginationTransition] = [:]
    private var generationByGroupId: [String: Int] = [:]

    func visibleCount(for groupId: String, totalCount: Int) -> Int {
        min(totalCount, visibleCountsByGroupId[groupId] ?? Self.pageSize)
    }

    func visibleSessions(in group: SessionListWorkspaceGroup) -> [CachedSession] {
        Array(group.sessions.prefix(visibleCount(for: group.id, totalCount: group.sessions.count)))
    }

    func canViewMore(groupId: String, totalCount: Int) -> Bool {
        visibleCount(for: groupId, totalCount: totalCount) < totalCount
    }

    func canViewLess(groupId: String, totalCount: Int) -> Bool {
        visibleCountsByGroupId[groupId] != nil && totalCount > Self.pageSize
    }

    mutating func revealMore(groupId: String, totalCount: Int) {
        let currentCount = visibleCount(for: groupId, totalCount: totalCount)
        visibleCountsByGroupId[groupId] = min(totalCount, currentCount + Self.pageSize)
    }

    mutating func showLess(groupId: String) {
        visibleCountsByGroupId.removeValue(forKey: groupId)
    }

    func transition(for groupId: String) -> SessionListPaginationTransition? {
        transitionByGroupId[groupId]
    }

    func isTransitioning(groupId: String) -> Bool {
        transitionByGroupId[groupId] != nil
    }

    func isRowVisible(groupId: String, index: Int) -> Bool {
        guard let transition = transitionByGroupId[groupId], index >= transition.stableCount else {
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
        groupId: String,
        totalCount: Int
    ) -> SessionListPaginationTransition? {
        guard transitionByGroupId[groupId] == nil else { return nil }
        let currentCount = visibleCount(for: groupId, totalCount: totalCount)
        let nextCount = min(totalCount, currentCount + Self.pageSize)
        guard nextCount > currentCount else { return nil }

        let transition = makeTransition(
            groupId: groupId,
            direction: .reveal,
            stableCount: currentCount,
            renderedCount: nextCount,
            phase: .layingOut
        )
        visibleCountsByGroupId[groupId] = nextCount
        transitionByGroupId[groupId] = transition
        return transition
    }

    mutating func beginShowLess(
        groupId: String,
        totalCount: Int
    ) -> SessionListPaginationTransition? {
        guard transitionByGroupId[groupId] == nil else { return nil }
        let currentCount = visibleCount(for: groupId, totalCount: totalCount)
        let stableCount = min(Self.pageSize, totalCount)
        guard currentCount > stableCount else { return nil }

        let transition = makeTransition(
            groupId: groupId,
            direction: .hide,
            stableCount: stableCount,
            renderedCount: currentCount,
            phase: .animatingRows
        )
        transitionByGroupId[groupId] = transition
        return transition
    }

    @discardableResult
    mutating func beginRevealRows(_ expected: SessionListPaginationTransition) -> Bool {
        guard var current = currentTransition(matching: expected),
              current.direction == .reveal,
              current.phase == .layingOut else { return false }
        current.phase = .animatingRows
        transitionByGroupId[current.groupId] = current
        return true
    }

    @discardableResult
    mutating func finish(_ expected: SessionListPaginationTransition) -> Bool {
        guard let current = currentTransition(matching: expected) else { return false }
        if current.direction == .hide {
            showLess(groupId: current.groupId)
        }
        transitionByGroupId.removeValue(forKey: current.groupId)
        return true
    }

    mutating func reconcile(groupCounts: [String: Int]) {
        let validGroupIds = Set(groupCounts.keys)
        visibleCountsByGroupId = visibleCountsByGroupId.filter { groupId, _ in
            validGroupIds.contains(groupId) && (groupCounts[groupId] ?? 0) > Self.pageSize
        }
        transitionByGroupId = transitionByGroupId.filter { groupId, transition in
            guard let totalCount = groupCounts[groupId] else { return false }
            return transition.stableCount <= totalCount && transition.renderedCount <= totalCount
        }
        generationByGroupId = generationByGroupId.filter { validGroupIds.contains($0.key) }
    }

    private mutating func makeTransition(
        groupId: String,
        direction: SessionListPaginationDirection,
        stableCount: Int,
        renderedCount: Int,
        phase: SessionListPaginationPhase
    ) -> SessionListPaginationTransition {
        let generation = (generationByGroupId[groupId] ?? 0) + 1
        generationByGroupId[groupId] = generation
        return SessionListPaginationTransition(
            groupId: groupId,
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
        guard let current = transitionByGroupId[expected.groupId],
              current.generation == expected.generation else { return nil }
        return current
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
    let groupId: String
    let direction: SessionListPaginationDirection
    let stableCount: Int
    let renderedCount: Int
    let generation: Int
    var phase: SessionListPaginationPhase

    var affectedCount: Int {
        max(renderedCount - stableCount, 0)
    }
}
