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
