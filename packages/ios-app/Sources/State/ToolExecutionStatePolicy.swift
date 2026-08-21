enum ToolExecutionStatePolicy {
    static func newest(
        _ current: ToolExecutionState,
        _ candidate: ToolExecutionState
    ) -> ToolExecutionState {
        shouldReplace(current, with: candidate) ? mergingLiveEvidence(from: current, into: candidate) : current
    }

    /// Live progress is a current display frame, not an append-only log. Install
    /// the latest nonempty frame in place while preserving the prior readable
    /// frame across empty advisory updates. Terminal nonempty output is authoritative.
    static func mergingLiveEvidence(
        from current: ToolExecutionState,
        into candidate: ToolExecutionState
    ) -> ToolExecutionState {
        let candidateOutput = nonempty(candidate.output)
        let candidateWasLocallyTruncated = (candidateOutput?.utf8.count ?? 0) > maximumLiveOutputBytes
        let output = candidateOutput.map(boundedLiveOutput) ?? current.output
        let outputTruncated = candidateOutput == nil
            ? current.outputTruncated
            : (candidate.outputTruncated == true || candidateWasLocallyTruncated ? true : nil)
        return ToolExecutionState(
            toolCallId: candidate.toolCallId,
            toolName: candidate.toolName,
            order: candidate.order,
            status: candidate.status,
            arguments: candidate.arguments,
            partialResult: candidate.partialResult ?? (candidate.status == .running ? current.partialResult : nil),
            result: candidate.result,
            output: output,
            outputTruncated: outputTruncated,
            isError: candidate.isError,
            startedAt: candidate.startedAt,
            updatedAt: candidate.updatedAt,
            lastProgressAt: candidate.lastProgressAt,
            completedAt: candidate.completedAt,
            durationMs: candidate.durationMs,
            progressSequence: candidate.progressSequence,
            extensionOrigin: candidate.extensionOrigin ?? current.extensionOrigin,
            extensionActivity: candidate.extensionActivity ?? (candidate.status == .running ? current.extensionActivity : nil),
            liveActivityRevision: candidate.liveActivityRevision ?? current.liveActivityRevision,
            extensionActivityAsOf: candidate.extensionActivityAsOf ?? current.extensionActivityAsOf,
            groupId: candidate.groupId ?? current.groupId,
            groupIndex: candidate.groupIndex ?? current.groupIndex,
            groupCount: candidate.groupCount ?? current.groupCount,
            groupFinalized: candidate.groupFinalized ?? current.groupFinalized
        )
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
        if left.groupFinalized == true, right.groupFinalized == true,
           left.groupId == right.groupId,
           let leftIndex = left.groupIndex, let rightIndex = right.groupIndex,
           leftIndex != rightIndex {
            return leftIndex < rightIndex
        }
        if let leftOrder = left.order, let rightOrder = right.order, leftOrder != rightOrder {
            return leftOrder < rightOrder
        }
        if left.order != nil, right.order == nil { return true }
        if left.order == nil, right.order != nil { return false }
        if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
        return left.toolCallId < right.toolCallId
    }

    private static let maximumLiveOutputBytes = 96 * 1_024

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func boundedLiveOutput(_ value: String) -> String {
        guard value.utf8.count > maximumLiveOutputBytes else { return value }
        let marker = "… earlier live output truncated by app …\n"
        let budget = max(256, maximumLiveOutputBytes - marker.utf8.count)
        let bytes = Array(value.utf8.suffix(budget))
        var start = 0
        while start < min(4, bytes.count), String(bytes: bytes[start...], encoding: .utf8) == nil { start += 1 }
        return marker + (String(bytes: bytes.dropFirst(start), encoding: .utf8) ?? "")
    }

    private static func statusRank(_ status: ToolExecutionState.Status) -> Int {
        switch status {
        case .running: 0
        case .completed, .failed: 1
        }
    }
}
