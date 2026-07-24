import Testing
@testable import TronMobile

@Suite("Session Context Presentation Tests")
struct SessionContextPresentationTests {
    @Test("Section rhythm separates sections while keeping labels attached")
    func sectionRhythm() {
        #expect(
            SessionContextPresentation.sectionSpacing
                > SessionContextPresentation.headerToContentSpacing
        )
        #expect(SessionContextPresentation.headerToContentSpacing == 4)
        #expect(SessionContextPresentation.headerToSubheaderSpacing == 0)
    }

    @Test("Context progress is bounded before rendering")
    func contextProgressIsBounded() {
        #expect(SessionContextPresentation.boundedPercentage(-4) == 0)
        #expect(SessionContextPresentation.boundedPercentage(42) == 42)
        #expect(SessionContextPresentation.boundedPercentage(140) == 100)
        #expect(SessionContextPresentation.progressFraction(42) == 0.42)
    }

    @Test("Context pressure changes only at the visible warning thresholds")
    func contextPressureThresholds() {
        #expect(SessionContextPresentation.pressure(for: 79) == .normal)
        #expect(SessionContextPresentation.pressure(for: 80) == .elevated)
        #expect(SessionContextPresentation.pressure(for: 94) == .elevated)
        #expect(SessionContextPresentation.pressure(for: 95) == .critical)
    }

    @Test("Session mutations require an idle protocol-ready session")
    func sessionMutationPolicy() {
        #expect(SessionContextPresentation.canMutate(
            isConnected: true,
            isAgentActive: false,
            isCompacting: false,
            isBusy: false
        ))
        #expect(!SessionContextPresentation.canMutate(
            isConnected: false,
            isAgentActive: false,
            isCompacting: false,
            isBusy: false
        ))
        #expect(!SessionContextPresentation.canMutate(
            isConnected: true,
            isAgentActive: true,
            isCompacting: false,
            isBusy: false
        ))
        #expect(!SessionContextPresentation.canMutate(
            isConnected: true,
            isAgentActive: false,
            isCompacting: true,
            isBusy: false
        ))
        #expect(!SessionContextPresentation.canMutate(
            isConnected: true,
            isAgentActive: false,
            isCompacting: false,
            isBusy: true
        ))
    }

    @Test("Session usage appears only when the engine has reported usage")
    func sessionUsageVisibility() {
        #expect(!SessionContextPresentation.hasSessionUsage(
            inputTokens: 0,
            outputTokens: 0,
            cost: 0
        ))
        #expect(SessionContextPresentation.hasSessionUsage(
            inputTokens: 1,
            outputTokens: 0,
            cost: 0
        ))
        #expect(SessionContextPresentation.hasSessionUsage(
            inputTokens: 0,
            outputTokens: 0,
            cost: 0.01
        ))
    }

    @Test("Remaining context avoids a false zero while the model window loads")
    func remainingContextText() {
        #expect(SessionContextPresentation.remainingContextText(
            currentContextWindow: 0,
            tokensRemaining: 0
        ) == "Window loading")
        #expect(SessionContextPresentation.remainingContextText(
            currentContextWindow: 100_000,
            tokensRemaining: 75_000
        ) == "75.0K tokens left")
    }

    @Test("Worker runs group by durable causal root and retain server ordering")
    func workerRunsGroupByCausalRoot() {
        let root = workerRun(id: "root", parent: nil)
        let child = workerRun(id: "child", parent: "root")
        let grandchild = workerRun(id: "grandchild", parent: "child")
        let secondRoot = workerRun(id: "root-2", parent: nil)

        let groups = SessionContextPresentation.causalGroups([
            root, child, grandchild, secondRoot
        ])

        #expect(groups.map(\.root.invocationId) == ["root", "root-2"])
        #expect(groups[0].descendants.map(\.invocationId) == ["child", "grandchild"])
        #expect(groups[1].descendants.isEmpty)
    }

    @Test("Detached active runs are explicit in Session Context")
    func detachedRunState() {
        #expect(SessionContextPresentation.runState(
            workerRun(id: "detached", parent: nil, detachedAt: "2026-07-24T12:00:10Z")
        ) == "Detached")
        #expect(SessionContextPresentation.runState(
            workerRun(id: "completed", parent: nil, status: "completed")
        ) == "Completed")
    }

    private func workerRun(
        id: String,
        parent: String?,
        status: String = "running",
        detachedAt: String? = nil
    ) -> WorkerInvocationDTO {
        WorkerInvocationDTO(
            invocationId: id,
            workerId: "worker",
            workerVersion: "v1",
            status: status,
            input: AnyCodable(["request": id]),
            output: nil,
            error: nil,
            idempotencyKey: "key-\(id)",
            traceId: "trace",
            causalDepth: parent == nil ? 0 : 1,
            triggerKind: "model_tool",
            originSessionId: "sess-origin",
            agentSessionId: nil,
            interactionMode: detachedAt == nil ? "foreground" : "background",
            detachedAt: detachedAt,
            parentWorkerInvocationId: parent,
            attemptCount: 1,
            createdAt: "2026-07-24T12:00:00Z",
            startedAt: "2026-07-24T12:00:00Z",
            completedAt: status == "completed" ? "2026-07-24T12:00:01Z" : nil
        )
    }
}
