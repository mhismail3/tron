enum ToolExecutionStatePolicy {
    static func newest(
        _ current: ToolExecutionState,
        _ candidate: ToolExecutionState
    ) -> ToolExecutionState {
        shouldReplace(current, with: candidate) ? candidate : current
    }

    static func shouldReplace(
        _ current: ToolExecutionState,
        with candidate: ToolExecutionState
    ) -> Bool {
        if let currentSequence = current.progressSequence,
           let candidateSequence = candidate.progressSequence,
           currentSequence != candidateSequence {
            return candidateSequence > currentSequence
        }
        if current.updatedAt != candidate.updatedAt { return candidate.updatedAt > current.updatedAt }
        return statusRank(candidate.status) >= statusRank(current.status)
    }

    static func orderedBefore(_ left: ToolExecutionState, _ right: ToolExecutionState) -> Bool {
        if let leftOrder = left.order, let rightOrder = right.order, leftOrder != rightOrder {
            return leftOrder < rightOrder
        }
        if left.order != nil, right.order == nil { return true }
        if left.order == nil, right.order != nil { return false }
        if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
        return left.toolCallId < right.toolCallId
    }

    private static func statusRank(_ status: ToolExecutionState.Status) -> Int {
        switch status {
        case .running: 0
        case .completed, .failed: 1
        }
    }
}
