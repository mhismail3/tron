import Testing
@testable import TronMobile

@Suite("Shared tool execution state policy")
struct ToolExecutionStatePolicyTests {
    @Test("progress sequence, timestamp, status, and ties preserve established newest semantics")
    func newestState() {
        let current = tool(id: "call", status: .running, updatedAt: "2026-01-01T00:00:02Z", sequence: 2)
        #expect(ToolExecutionStatePolicy.newest(
            current,
            tool(id: "call", status: .completed, updatedAt: "2026-01-01T00:00:03Z", sequence: 1)
        ) == current)

        let newerTime = tool(id: "call", status: .running, updatedAt: "2026-01-01T00:00:03Z")
        #expect(ToolExecutionStatePolicy.newest(
            tool(id: "call", status: .completed, updatedAt: "2026-01-01T00:00:02Z"),
            newerTime
        ) == newerTime)

        let completed = tool(id: "call", status: .completed, updatedAt: "same")
        #expect(ToolExecutionStatePolicy.newest(
            tool(id: "call", status: .running, updatedAt: "same"),
            completed
        ) == completed)

        let tieCandidate = tool(id: "call", status: .failed, updatedAt: "same")
        #expect(ToolExecutionStatePolicy.newest(completed, tieCandidate) == tieCandidate)
    }

    @Test("explicit order, missing order, start time, and call ID preserve established sorting")
    func ordering() {
        let explicitFirst = tool(id: "z", order: 1, startedAt: "later")
        let explicitSecond = tool(id: "a", order: 2, startedAt: "earlier")
        let unordered = tool(id: "b", startedAt: "earlier")
        #expect(ToolExecutionStatePolicy.orderedBefore(explicitFirst, explicitSecond))
        #expect(ToolExecutionStatePolicy.orderedBefore(explicitSecond, unordered))

        let earlier = tool(id: "z", startedAt: "2026-01-01T00:00:00Z")
        let later = tool(id: "a", startedAt: "2026-01-01T00:00:01Z")
        #expect(ToolExecutionStatePolicy.orderedBefore(earlier, later))
        #expect(ToolExecutionStatePolicy.orderedBefore(
            tool(id: "a", startedAt: "same"),
            tool(id: "b", startedAt: "same")
        ))
    }

    private func tool(
        id: String,
        order: Int? = nil,
        status: ToolExecutionState.Status = .running,
        startedAt: String = "2026-01-01T00:00:00Z",
        updatedAt: String = "2026-01-01T00:00:00Z",
        sequence: Int? = nil
    ) -> ToolExecutionState {
        ToolExecutionState(
            toolCallId: id,
            toolName: "tool",
            order: order,
            status: status,
            arguments: .object([:]),
            partialResult: nil,
            result: nil,
            isError: status == .failed,
            startedAt: startedAt,
            updatedAt: updatedAt,
            progressSequence: sequence
        )
    }
}
