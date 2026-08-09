import Testing
@testable import TronMobile

@Suite("Session Context Presentation Tests")
struct SessionContextPresentationTests {
    @Test("The session operations sheet uses its product-facing name")
    func sheetTitle() {
        #expect(SessionContextPresentation.sheetTitle == "Manage Session")
        #expect(SessionContextPresentation.terminalActionTitle == "Terminal")
    }

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

    @Test("Terminal remains represented while transport or capability is unavailable")
    func terminalAvailability() {
        #expect(SessionContextPresentation.terminalAvailability(
            isConnected: false,
            isSupported: true
        ) == SessionTerminalAvailability(
            isEnabled: false,
            detail: "Available after reconnection"
        ))
        #expect(SessionContextPresentation.terminalAvailability(
            isConnected: true,
            isSupported: false
        ) == SessionTerminalAvailability(
            isEnabled: false,
            detail: "Requires a server with native Terminal support"
        ))
        #expect(SessionContextPresentation.terminalAvailability(
            isConnected: true,
            isSupported: true
        ) == SessionTerminalAvailability(
            isEnabled: true,
            detail: "Open a native shell in this session’s workspace"
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

    @Test("Background delivery refresh retains a settled empty snapshot")
    func deliveryWaitEmptyStateDoesNotFlicker() {
        #expect(SessionContextPresentation.deliveryWaitEmptyState(
            error: nil,
            isLoading: true,
            hasLoadedSnapshot: false
        ) == "Loading durable update state…")
        #expect(SessionContextPresentation.deliveryWaitEmptyState(
            error: nil,
            isLoading: true,
            hasLoadedSnapshot: true
        ) == "No deliveries or waits are recorded.")
        #expect(SessionContextPresentation.deliveryWaitEmptyState(
            error: "Couldn’t refresh; showing the last update.",
            isLoading: false,
            hasLoadedSnapshot: true
        ) == "Couldn’t refresh; showing the last update.")
    }

    @Test("Cache percentage is bounded and handles zero input")
    func cachePercentage() {
        #expect(SessionContextPresentation.cacheReadPercentage(
            cacheReadTokens: 0,
            totalInputTokens: 0
        ) == 0)
        #expect(SessionContextPresentation.cacheReadPercentage(
            cacheReadTokens: 250,
            totalInputTokens: 1_000
        ) == 25)
        #expect(SessionContextPresentation.cacheReadPercentage(
            cacheReadTokens: 2_000,
            totalInputTokens: 1_000
        ) == 100)
    }

    @Test("Automatic context distinguishes reference and historical system delivery")
    func automaticContextDeliveryLabels() {
        #expect(SessionContextPresentation.automaticContextChannel(
            automaticEvaluation(deliveryChannel: "reference", narrative: "memory")
        ) == "Reference context")
        #expect(SessionContextPresentation.automaticContextChannel(
            automaticEvaluation(deliveryChannel: nil, narrative: "legacy memory")
        ) == "System context (historical)")
        #expect(SessionContextPresentation.automaticContextChannel(
            automaticEvaluation(deliveryChannel: "none", narrative: nil)
        ) == "Not delivered")
    }

    @Test("Request audits use the catalog's friendly model name")
    func requestAuditModelDisplayName() {
        let model = ModelInfo(
            id: "openai/gpt-5.6-sol",
            name: "GPT-5.6 Sol",
            provider: "openai",
            contextWindow: 272_000,
            supportsThinking: true,
            supportsImages: true,
            supportsDocuments: true,
            tier: "sol",
            isRetiredGeneration: false
        )

        #expect(SessionContextPresentation.modelDisplayName(
            "gpt-5.6-sol",
            models: [model],
            fallback: "Current Model"
        ) == "GPT-5.6 Sol")
        #expect(SessionContextPresentation.modelDisplayName(
            "gpt-5.6-sol",
            models: [],
            fallback: "Current Model"
        ) == "GPT-5.6 Sol")
        #expect(SessionContextPresentation.modelDisplayName(
            nil,
            models: [model],
            fallback: "Current Model"
        ) == "Current Model")
    }

    @Test("Remaining context does not claim a restored model window is loading")
    func remainingContextText() {
        #expect(SessionContextPresentation.remainingContextText(
            currentContextWindow: 0,
            tokensRemaining: 0
        ) == "Context usage")
        #expect(SessionContextPresentation.remainingContextText(
            currentContextWindow: 100_000,
            tokensRemaining: 75_000
        ) == "75.0K tokens left")
    }

    @Test("Catalog window repairs restored zero-window presentation")
    func catalogWindowFallback() {
        #expect(SessionContextPresentation.resolvedContextWindow(
            trackedWindow: 0,
            modelWindow: 272_000
        ) == 272_000)
        #expect(SessionContextPresentation.resolvedContextWindow(
            trackedWindow: 200_000,
            modelWindow: nil
        ) == 200_000)
        #expect(SessionContextPresentation.contextPercentage(
            tokensUsed: 14_100,
            contextWindow: 272_000
        ) == 5)
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

    @Test("Request tool evidence preserves selected and omitted workers")
    func requestWorkerSelectionEvidence() {
        let surface = AnyCodable([
            "fixedTools": [
                [
                    "functionId": "worker_kernel::filesystem_read",
                    "modelName": "filesystem_read",
                    "exposed": true,
                    "audience": "ordinary",
                    "accessPath": "ordinary",
                    "selectionReason": "ordinary",
                ] as [String: Any],
                [
                    "functionId": "worker_kernel::upsert",
                    "modelName": "worker_upsert",
                    "exposed": false,
                    "audience": "specialist",
                    "accessPath": "specialist_worker",
                    "selectionReason": "not_projected",
                    "omissionReason": "specialist_only",
                ] as [String: Any],
            ],
            "availableWorkers": [
                [
                    "workerId": "research",
                    "modelName": "worker_research",
                    "workerVersion": "v2",
                    "projected": true,
                    "selectionReason": "relevance",
                    "rankingMechanism": "semantic_hook",
                    "relevanceScore": 900,
                    "routerExplanation": "Research directly matches this request.",
                ] as [String: Any],
                [
                    "workerId": "memory",
                    "modelName": "worker_memory",
                    "workerVersion": "v4",
                    "projected": false,
                    "omissionReason": "selection_limit",
                    "rankingMechanism": "deterministic_fallback",
                    "relevanceScore": 20,
                ] as [String: Any],
            ],
        ] as [String: Any])

        let workers = SessionContextPresentation.workerSelections(from: surface)
        let fixed = SessionContextPresentation.fixedToolSelections(from: surface)
        let summary = SessionContextPresentation.toolSummary(
            fixed: fixed,
            workers: workers
        )

        #expect(workers.count == 2)
        #expect(workers[0].projected)
        #expect(workers[0].selectionReason == "relevance")
        #expect(workers[0].mechanism == "semantic_hook")
        #expect(workers[0].explanation == "Research directly matches this request.")
        #expect(!workers[1].projected)
        #expect(workers[1].omissionReason == "selection_limit")
        #expect(fixed.count == 2)
        #expect(fixed[0].projected)
        #expect(fixed[0].audience == "ordinary")
        #expect(!fixed[1].projected)
        #expect(fixed[1].omissionReason == "specialist_only")
        #expect(summary.fixedAvailable == 1)
        #expect(summary.workersAvailable == 1)
        #expect(summary.omitted == 2)
    }

    @Test("Agent updates name their worker and use user-facing delivery states")
    func agentUpdatePresentation() {
        #expect(SessionContextPresentation.agentUpdateTitle(
            sourceKind: "worker_result",
            sourceWorkerId: "continuity-curator",
            sourceWorkerName: "Continuity Memory Curator"
        ) == "Continuity Memory Curator")
        #expect(SessionContextPresentation.agentUpdateTitle(
            sourceKind: "agent_message",
            sourceWorkerId: nil
        ) == "Agent Message")
        #expect(SessionContextPresentation.agentUpdateStatusLabel(
            status: "pending",
            wakePolicy: "passive"
        ) == "Available")
        #expect(SessionContextPresentation.agentUpdateStatusLabel(
            status: "pending",
            wakePolicy: "wake"
        ) == "Will resume")
        #expect(SessionContextPresentation.agentUpdateStatusLabel(
            status: "observed",
            wakePolicy: "passive"
        ) == "Seen")
        #expect(SessionContextPresentation.agentUpdateStatusLabel(
            status: "prepared",
            wakePolicy: "passive"
        ) == "In request")
        #expect(
            SessionContextPresentation.agentUpdateStatusLabel(
                status: "retry_exhausted",
                wakePolicy: "passive"
            )
                == "Resume failed"
        )
        #expect(SessionContextPresentation.agentUpdateStateDescription(
            status: "pending",
            wakePolicy: "passive",
            boundary: "next_turn"
        ).contains("will not resume"))
        #expect(SessionContextPresentation.agentUpdateStateDescription(
            status: "pending",
            wakePolicy: "wake",
            boundary: "next_run"
        ).contains("resume this task"))
        #expect(
            SessionContextPresentation.agentWaitStatusLabel(status: "pending")
                == "Auto-resume"
        )
        #expect(SessionContextPresentation.agentWaitDescription(
            status: "pending",
            mode: "all"
        ).contains("all selected workers"))
        #expect(SessionContextPresentation.isActiveAgentUpdate(status: "pending"))
        #expect(!SessionContextPresentation.isActiveAgentUpdate(status: "observed"))
        #expect(SessionContextPresentation.isActiveAgentWait(status: "pending"))
        #expect(!SessionContextPresentation.isActiveAgentWait(status: "satisfied"))
    }

    @Test("Included worker updates have a friendly summary while retaining exact content")
    func includedDeliveryPresentation() {
        let content = """
        {"kind":"worker_result","workerId":"wait-ux-smoke","workerName":"Wait UX Smoke Test","status":"completed","evidence":{"preview":"Background worker finished successfully."}}
        """

        #expect(SessionContextPresentation.includedDeliveryTitle(
            sourceKind: "worker_result",
            content: content
        ) == "Wait UX Smoke Test")
        #expect(SessionContextPresentation.includedDeliverySummary(
            sourceKind: "worker_result",
            content: content
        ) == "Background worker finished successfully.")
        #expect(SessionContextPresentation.includedDeliverySummary(
            sourceKind: "worker_result",
            content: """
            {"kind":"worker_result","status":"completed","evidence":{"preview":"empty"}}
            """
        ) == "Completed without a user-facing result summary.")
        #expect(SessionContextPresentation.includedDeliverySummary(
            sourceKind: "worker_result",
            content: """
            {"kind":"worker_result","status":"failed","evidence":{"error":"provider setup failed"}}
            """
        ) == "Failed: provider setup failed")
        #expect(SessionContextPresentation.includedDeliveryTitle(
            sourceKind: "worker_result",
            content: #"{"unexpected":"bounded technical evidence"}"#
        ) == "Worker update")
        #expect(SessionContextPresentation.includedDeliverySummary(
            sourceKind: "worker_result",
            content: #"{"unexpected":"bounded technical evidence"}"#
        ) == "A durable worker result was included in this model request.")
    }

    @Test("Delivery observation runs only while useful live state can change")
    func deliveryObservationPolicy() {
        #expect(SessionContextPresentation.shouldContinueObservingDeliveryState(
            isAgentActive: true,
            hasRunningWorker: false,
            updates: [],
            waitStatuses: []
        ))
        #expect(SessionContextPresentation.shouldContinueObservingDeliveryState(
            isAgentActive: false,
            hasRunningWorker: true,
            updates: [],
            waitStatuses: []
        ))
        #expect(SessionContextPresentation.shouldContinueObservingDeliveryState(
            isAgentActive: false,
            hasRunningWorker: false,
            updates: [(status: "pending", wakePolicy: "wake")],
            waitStatuses: []
        ))
        #expect(SessionContextPresentation.shouldContinueObservingDeliveryState(
            isAgentActive: false,
            hasRunningWorker: false,
            updates: [],
            waitStatuses: ["pending"]
        ))
        #expect(!SessionContextPresentation.shouldContinueObservingDeliveryState(
            isAgentActive: false,
            hasRunningWorker: false,
            updates: [(status: "pending", wakePolicy: "passive")],
            waitStatuses: ["satisfied"]
        ))
    }

    @Test("Provider audit formatter never renders inline media bytes")
    func providerAuditMediaProjection() {
        let audit = AnyCodable([
            "image_url": "data:image/png;base64," + String(repeating: "a", count: 512),
            "text": "visible",
        ])

        let rendered = SessionContextAuditFormatter.projectedJSONString(audit)

        #expect(rendered.contains("[media omitted:"))
        #expect(rendered.contains("visible"))
        #expect(!rendered.contains(String(repeating: "a", count: 128)))
    }

    @Test("Provider audit overview avoids formatting the full request body")
    func providerAuditOverview() {
        let audit = AnyCodable([
            "messageCount": 3,
            "toolCount": 16,
            "providerRequest": [
                "kind": "exact_provider_envelope",
                "body": ["tools": Array(repeating: ["schema": "large"], count: 16)],
            ] as [String: Any],
        ] as [String: Any])

        let overview = SessionContextAuditFormatter.providerRequestOverview(audit)

        #expect(overview.requestKind == "exact_provider_envelope")
        #expect(overview.messageCount == 3)
        #expect(overview.toolCount == 16)
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

    private func automaticEvaluation(
        deliveryChannel: String?,
        narrative: String?
    ) -> ContextAutomaticEvaluationDTO {
        ContextAutomaticEvaluationDTO(
            kind: "continuity",
            outcome: narrative == nil ? "empty" : "injected",
            mechanism: "continuity_hook",
            deliveryChannel: deliveryChannel,
            narrative: narrative,
            workerId: "continuity-curator",
            workerVersion: "v1",
            invocationId: "invocation",
            sources: [],
            detail: nil
        )
    }
}
