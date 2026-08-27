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

    @Test("live output replaces in place while empty progress preserves the last readable frame")
    func replacingLiveOutput() {
        let first = tool(
            id: "call", updatedAt: "1", sequence: 1,
            output: "Waiting\nworker: thinking", outputTruncated: true,
            toolSegmentId: "tool-segment:turn"
        )
        let empty = ToolExecutionStatePolicy.newest(first, tool(id: "call", updatedAt: "2", sequence: 2))
        #expect(empty.output == first.output)
        #expect(empty.outputTruncated == true)
        #expect(empty.toolSegmentId == "tool-segment:turn")
        let shorter = ToolExecutionStatePolicy.newest(
            empty,
            tool(id: "call", updatedAt: "3", sequence: 3, output: "Waiting")
        )
        #expect(shorter.output == "Waiting")
        #expect(shorter.outputTruncated == nil)
        let latest = ToolExecutionStatePolicy.newest(
            shorter,
            tool(id: "call", updatedAt: "4", sequence: 4, output: "worker: read complete")
        )
        #expect(latest.output == "worker: read complete")
        let terminal = ToolExecutionStatePolicy.newest(
            latest,
            tool(id: "call", status: .completed, updatedAt: "5", sequence: 5, output: "final result")
        )
        #expect(terminal.output == "final result")
    }

    @Test("terminal result wins while the selected latest frame stays bounded")
    func terminalResultAndBoundedOutput() {
        let latest = String(repeating: "b", count: 100 * 1_024)
        let merged = ToolExecutionStatePolicy.newest(
            tool(id: "call", updatedAt: "1", sequence: 1, output: "discarded old frame"),
            tool(id: "call", updatedAt: "2", sequence: 2, output: latest)
        )
        #expect(merged.output?.utf8.count ?? 0 <= 96 * 1_024)
        #expect(merged.output?.contains("discarded old frame") == false)
        #expect(merged.outputTruncated == true)

        let terminal = ToolExecutionStatePolicy.newest(
            merged,
            ToolExecutionState(
                toolCallId: "call", toolName: "tool", status: .completed,
                arguments: .object([:]), partialResult: nil,
                result: .string("final result"), output: nil,
                isError: false, startedAt: "2026-01-01T00:00:00Z",
                updatedAt: "3", progressSequence: 3
            )
        )
        #expect(terminal.result == .string("final result"))
        #expect(terminal.output == merged.output)
    }

    @Test("producer order, group order, missing order, and call ID preserve deterministic sorting")
    func ordering() {
        let explicitFirst = tool(id: "z", order: 1, startedAt: "later")
        let explicitSecond = tool(id: "a", order: 2, startedAt: "earlier")
        let unordered = tool(id: "b", startedAt: "earlier")
        #expect(ToolExecutionStatePolicy.orderedBefore(explicitFirst, explicitSecond))
        #expect(ToolExecutionStatePolicy.orderedBefore(explicitSecond, unordered))

        // Timestamps are freshness metadata, never a placement tie-breaker.
        let earlier = tool(id: "z", startedAt: "2026-01-01T00:00:00Z")
        let later = tool(id: "a", startedAt: "2026-01-01T00:00:01Z")
        #expect(!ToolExecutionStatePolicy.orderedBefore(earlier, later))
        #expect(ToolExecutionStatePolicy.orderedBefore(
            tool(id: "a", startedAt: "later"),
            tool(id: "b", startedAt: "earlier")
        ))
        #expect(ToolExecutionStatePolicy.orderedBefore(
            tool(id: "late", groupIndex: 1),
            tool(id: "early", groupIndex: 2)
        ))
    }

    private func tool(
        id: String,
        order: Int? = nil,
        status: ToolExecutionState.Status = .running,
        startedAt: String = "2026-01-01T00:00:00Z",
        updatedAt: String = "2026-01-01T00:00:00Z",
        sequence: Int? = nil,
        output: String? = nil,
        outputTruncated: Bool? = nil,
        toolSegmentId: String? = nil,
        groupIndex: Int? = nil
    ) -> ToolExecutionState {
        ToolExecutionState(
            toolCallId: id,
            toolName: "tool",
            order: order,
            status: status,
            arguments: .object([:]),
            partialResult: nil,
            result: nil,
            output: output,
            outputTruncated: outputTruncated,
            isError: status == .failed,
            startedAt: startedAt,
            updatedAt: updatedAt,
            progressSequence: sequence,
            toolSegmentId: toolSegmentId,
            groupId: groupIndex == nil ? nil : "group",
            groupIndex: groupIndex,
            groupCount: groupIndex == nil ? nil : 3,
            groupFinalized: groupIndex != nil
        )
    }
}
