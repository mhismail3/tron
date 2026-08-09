import Testing
import Foundation
@testable import TronMobile

@Suite("Reconstruction metadata decoding")
struct ReconstructionMetadataDecodingTests {
    @Test("Latest context inventory decodes without the provider audit body")
    func latestContextInventoryDecodes() throws {
        let data = Data("""
        {
          "model":"gpt-5.6-sol",
          "turnCount":26,
          "workingDirectory":"/workspace",
          "title":"Research",
          "tokenUsage":null,
          "totalCost":3.69,
          "latestContextRequest":{
            "eventId":"provider-request-26",
            "sequence":178,
            "timestamp":"2026-08-07T12:00:00Z",
            "format":"tron.model_provider_request.v4",
            "turn":26,
            "providerType":"openai",
            "providerName":"OpenAI",
            "model":"gpt-5.6-sol",
            "requestClassification":"interactive",
            "messageCount":62,
            "toolCount":23,
            "automaticContextCount":0,
            "instructionCount":2,
            "attachmentMessageCount":0,
            "agentDeliveryCount":0,
            "environmentAvailable":true,
            "manifestAvailable":true,
            "provenanceAvailability":"complete"
          }
        }
        """.utf8)

        let metadata = try JSONDecoder().decode(ReconstructMetadata.self, from: data)
        let summary = try #require(metadata.latestContextRequest)

        #expect(summary.eventId == "provider-request-26")
        #expect(summary.messageCount == 62)
        #expect(summary.toolCount == 23)
    }

    @Test("Older reconstruction metadata remains compatible")
    func metadataWithoutContextInventoryDecodes() throws {
        let data = Data("""
        {
          "model":"gpt-5.6-sol",
          "turnCount":1,
          "workingDirectory":"/workspace",
          "title":"Legacy",
          "tokenUsage":null,
          "totalCost":0.01
        }
        """.utf8)

        let metadata = try JSONDecoder().decode(ReconstructMetadata.self, from: data)

        #expect(metadata.latestContextRequest == nil)
    }
}

@Suite("SessionInfo Tests")
struct SessionInfoTests {

    private func makeSessionInfo(
        sessionId: String = "sess_abc123def456789012345",
        inputTokens: Int? = 1000,
        outputTokens: Int? = 500,
        cacheReadTokens: Int? = 200,
        cacheCreationTokens: Int? = 100,
        cost: Double? = 1.23,
        turnCount: Int? = 7,
        parentSessionId: String? = nil
    ) -> SessionInfo {
        let json: [String: Any] = [
            "sessionId": sessionId,
            "model": "claude-sonnet-4-6",
            "createdAt": "2026-04-01T00:00:00Z",
            "turnCount": turnCount as Any,
            "messageCount": 10,
            "inputTokens": inputTokens as Any,
            "outputTokens": outputTokens as Any,
            "cacheReadTokens": cacheReadTokens as Any,
            "cacheCreationTokens": cacheCreationTokens as Any,
            "cost": cost as Any,
            "isActive": true,
            "parentSessionId": parentSessionId as Any,
        ].compactMapValues { $0 is NSNull ? nil : $0 }

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SessionInfo.self, from: data)
    }

    // MARK: - displayName

    @Test("displayName truncates to 20 chars")
    func displayNameTruncated() {
        let info = makeSessionInfo(sessionId: "sess_abc123def456789012345")
        #expect(info.displayName == "sess_abc123def456789") // First 20 chars
        #expect(info.displayName.count == 20)
    }

    @Test("displayName short sessionId returns full string")
    func displayNameShort() {
        let info = makeSessionInfo(sessionId: "short")
        #expect(info.displayName == "short")
    }

    // MARK: - totalInputTokens

    @Test("totalInputTokens sums input and cache read")
    func totalInputTokensSum() {
        let info = makeSessionInfo(inputTokens: 1000, cacheReadTokens: 500)
        #expect(info.totalInputTokens == 1500)
    }

    @Test("turnCount decodes from session list payload")
    func turnCountDecodes() {
        let info = makeSessionInfo(turnCount: 3)
        #expect(info.turnCount == 3)
    }

    @Test("totalInputTokens with nil inputTokens")
    func totalInputTokensNilInput() {
        let info = makeSessionInfo(inputTokens: nil, cacheReadTokens: 500)
        #expect(info.totalInputTokens == 500)
    }

    @Test("totalInputTokens with nil cacheRead")
    func totalInputTokensNilCache() {
        let info = makeSessionInfo(inputTokens: 1000, cacheReadTokens: nil)
        #expect(info.totalInputTokens == 1000)
    }

    @Test("totalInputTokens both nil")
    func totalInputTokensBothNil() {
        let info = makeSessionInfo(inputTokens: nil, cacheReadTokens: nil)
        #expect(info.totalInputTokens == 0)
    }

    // MARK: - formattedCacheTokens

    @Test("formattedCacheTokens both zero returns nil")
    func cacheTokensBothZero() {
        let info = makeSessionInfo(cacheReadTokens: 0, cacheCreationTokens: 0)
        #expect(info.formattedCacheTokens == nil)
    }

    @Test("formattedCacheTokens both nil returns nil")
    func cacheTokensBothNil() {
        let info = makeSessionInfo(cacheReadTokens: nil, cacheCreationTokens: nil)
        #expect(info.formattedCacheTokens == nil)
    }

    @Test("formattedCacheTokens one non-zero returns formatted string")
    func cacheTokensOneNonZero() {
        let info = makeSessionInfo(cacheReadTokens: 1000, cacheCreationTokens: 0)
        let result = info.formattedCacheTokens
        #expect(result != nil)
        #expect(result!.contains("read"))
        #expect(result!.contains("write"))
    }

    // MARK: - formattedCost

    @Test("formattedCost nil shows less than penny")
    func costNil() {
        let info = makeSessionInfo(cost: nil)
        #expect(info.formattedCost == "<$0.01")
    }

    @Test("formattedCost zero shows less than penny")
    func costZero() {
        let info = makeSessionInfo(cost: 0)
        #expect(info.formattedCost == "<$0.01")
    }

    @Test("formattedCost sub-penny shows less than penny")
    func costSubPenny() {
        let info = makeSessionInfo(cost: 0.005)
        #expect(info.formattedCost == "<$0.01")
    }

    @Test("formattedCost normal amount")
    func costNormal() {
        let info = makeSessionInfo(cost: 1.23)
        #expect(info.formattedCost == "$1.23")
    }

    @Test("formattedCost exactly one cent")
    func costOneCent() {
        let info = makeSessionInfo(cost: 0.01)
        #expect(info.formattedCost == "$0.01")
    }

    @Test("formattedCost negative — documents edge case")
    func costNegative() {
        // Negative cost < 0.01, so shows "<$0.01" — technically misleading for refunds
        let info = makeSessionInfo(cost: -0.05)
        #expect(info.formattedCost == "<$0.01")
    }

    // MARK: - isFork

    @Test("isFork true when parentSessionId set")
    func isForkTrue() {
        let info = makeSessionInfo(parentSessionId: "parent-sess")
        #expect(info.isFork == true)
    }

    @Test("isFork false when parentSessionId nil")
    func isForkFalse() {
        let info = makeSessionInfo(parentSessionId: nil)
        #expect(info.isFork == false)
    }

    @Test("canonical labels and group decode without an organizer shadow model")
    func organizationProjectionDecodes() throws {
        let data = Data("""
        {
          "sessionId":"sess-organized",
          "model":"model",
          "createdAt":"2026-07-27T00:00:00Z",
          "messageCount":2,
          "isActive":false,
          "labels":["Work","Follow Up"],
          "organizationGroup":"Projects"
        }
        """.utf8)
        let info = try JSONDecoder().decode(SessionInfo.self, from: data)
        #expect(info.labels == ["Work", "Follow Up"])
        #expect(info.organizationGroup == "Projects")
    }
}

@Suite("SessionCreateParams encoding")
struct SessionCreateParamsEncodingTests {
    @Test("create encodes exactly the strict server-owned fields")
    func strictCreateSchemaEncodes() {
        let params = SessionCreateParams(
            workingDirectory: "/tmp",
            model: "gpt-5.4",
            title: "Worker proof"
        )
        let data = try! JSONEncoder().encode(params)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["workingDirectory"] as? String == "/tmp")
        #expect(json["model"] as? String == "gpt-5.4")
        #expect(json["title"] as? String == "Worker proof")
        #expect(Set(json.keys) == Set(["workingDirectory", "model", "title"]))
    }

    @Test("source-control placement is one closed nested value")
    func sourceControlPlacementEncodes() {
        let params = SessionCreateParams(
            workingDirectory: "/tmp",
            model: "gpt-5.6-sol",
            sourceControl: SessionSourceControlSelection(placement: .worktree)
        )
        let data = try! JSONEncoder().encode(params)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sourceControl = json["sourceControl"] as? [String: Any]

        #expect(sourceControl?["placement"] as? String == "worktree")
        #expect(sourceControl?.count == 1)
        #expect(Set(json.keys) == Set(["workingDirectory", "model", "sourceControl"]))
    }
}

@Suite("Session context audit decoding")
struct SessionContextAuditDecodingTests {
    @Test("V3 detail decodes automatic context, sources, and message event provenance")
    func v3DetailDecodes() throws {
        let data = Data("""
        {
          "eventId":"event-request-1",
          "sequence":42,
          "timestamp":"2026-07-27T12:00:00Z",
          "format":"tron.model_provider_request.v3",
          "contextManifest":{
            "systemContributions":[{
              "kind":"continuity_context",
              "label":"Continuity context",
              "content":"Remember the device gate.",
              "byteCount":25,
              "sha256":"sha256:system",
              "provenance":{"workerId":"continuity-curator"}
            }],
            "messages":[{
              "ordinal":0,
              "role":"user",
              "contentKinds":["text"],
              "byteCount":12,
              "sha256":"sha256:message",
              "preview":"Run acceptance",
              "projection":"provider_visible",
              "sourceKind":"durable_event",
              "sourceEventIds":["event-user-1"],
              "sourceModels":["gpt-5.6-sol"],
              "sourceTools":["request_user_input"],
              "sourceTurns":[7]
            }],
            "toolSurface":{"availableWorkers":[]},
            "automaticContext":[{
              "kind":"continuity",
              "outcome":"injected",
              "mechanism":"engine_hook",
              "deliveryChannel":"reference",
              "narrative":"Remember the device gate.",
              "workerId":"continuity-curator",
              "workerVersion":"version-2",
              "invocationId":"invocation-2",
              "sources":[{
                "memoryId":"memory-1",
                "revision":2,
                "scope":"project"
              }]
            }],
            "environment":{"sha256":"sha256:environment"},
            "cacheLayout":{
              "stableInstructionBytes":1024,
              "stableInstructionSha256":"sha256:instructions",
              "fixedToolCount":11,
              "fixedToolSchemaBytes":4096,
              "fixedToolPrefixSha256":"sha256:fixed",
              "dynamicToolCount":3,
              "dynamicToolSchemaBytes":2048,
              "dynamicToolsSha256":"sha256:dynamic",
              "requestContextBytes":512,
              "requestContextSha256":"sha256:reference"
            },
            "systemPromptSha256":"sha256:system",
            "messagesSha256":"sha256:messages",
            "toolsSha256":"sha256:tools",
            "contextSha256":"sha256:context"
          },
          "providerAdditions":[{
            "kind":"provider_system_prefix",
            "label":"Anthropic provider instructions",
            "content":"Provider-owned prefix",
            "byteCount":21,
            "sha256":"sha256:provider",
            "provenance":{"owner":"anthropic"}
          }],
          "providerAudit":{"providerRequest":{"kind":"exact_provider_envelope"}},
          "provenanceAvailability":"complete"
        }
        """.utf8)

        let detail = try JSONDecoder().decode(SessionContextRequestDetailDTO.self, from: data)

        #expect(detail.contextManifest?.automaticContext.first?.sources.count == 1)
        #expect(detail.contextManifest?.automaticContext.first?.deliveryChannel == "reference")
        #expect(detail.contextManifest?.cacheLayout?.fixedToolCount == 11)
        #expect(detail.contextManifest?.cacheLayout?.requestContextBytes == 512)
        #expect(detail.contextManifest?.messages.first?.sourceKind == "durable_event")
        #expect(detail.contextManifest?.messages.first?.sourceEventIds == ["event-user-1"])
        #expect(detail.contextManifest?.messages.first?.sourceModels == ["gpt-5.6-sol"])
        #expect(detail.contextManifest?.messages.first?.sourceTools == ["request_user_input"])
        #expect(detail.contextManifest?.messages.first?.sourceTurns == [7])
        #expect(detail.providerAdditions?.first?.kind == "provider_system_prefix")
        #expect(detail.provenanceAvailability == "complete")
    }

    @Test("V3 manifest accepts omitted empty provenance arrays")
    func v3ManifestAcceptsOmittedEmptyProvenance() throws {
        let data = Data("""
        {
          "eventId":"event-request-empty-provenance",
          "sequence":43,
          "timestamp":"2026-07-28T07:19:34Z",
          "format":"tron.model_provider_request.v3",
          "contextManifest":{
            "systemContributions":[{
              "kind":"base_instructions",
              "label":"Agent instructions",
              "content":"Follow the request.",
              "byteCount":19,
              "sha256":"sha256:system"
            }],
            "messages":[{
              "ordinal":0,
              "role":"user",
              "contentKinds":["text"],
              "byteCount":27,
              "sha256":"sha256:message",
              "preview":"Tell me what you can do",
              "projection":"provider_visible",
              "sourceKind":"generated"
            }],
            "toolSurface":{"fixedTools":[],"availableWorkers":[]},
            "automaticContext":[{
              "kind":"continuity",
              "outcome":"empty",
              "mechanism":"continuity_hook",
              "deliveryChannel":"none"
            }],
            "environment":{"sha256":"sha256:environment"},
            "systemPromptSha256":"sha256:system",
            "messagesSha256":"sha256:messages",
            "toolsSha256":"sha256:tools",
            "contextSha256":"sha256:context"
          },
          "providerAudit":{
            "messageCount":1,
            "toolCount":11,
            "providerRequest":{"kind":"exact_provider_envelope"}
          },
          "provenanceAvailability":"complete"
        }
        """.utf8)

        let detail = try JSONDecoder().decode(SessionContextRequestDetailDTO.self, from: data)

        #expect(detail.contextManifest?.systemContributions.count == 1)
        #expect(detail.contextManifest?.messages.first?.sourceEventIds == [])
        #expect(detail.contextManifest?.messages.first?.sourceModels == [])
        #expect(detail.contextManifest?.messages.first?.sourceTools == [])
        #expect(detail.contextManifest?.messages.first?.sourceTurns == [])
        #expect(detail.contextManifest?.automaticContext.first?.sources == [])
        #expect(detail.contextManifest?.agentDeliveries == [])
    }

    @Test("V4 detail decodes exact agent delivery evidence")
    func v4AgentDeliveryDecodes() throws {
        let data = Data("""
        {
          "eventId":"event-request-delivery",
          "sequence":44,
          "timestamp":"2026-07-28T07:20:00Z",
          "format":"tron.model_provider_request.v4",
          "contextManifest":{
            "systemContributions":[],
            "messages":[{
              "ordinal":0,
              "role":"user",
              "contentKinds":["text"],
              "byteCount":20,
              "sha256":"sha256:message",
              "preview":"Durable user history",
              "projection":"provider_visible",
              "sourceKind":"durable_event",
              "sourceEventIds":["event-user"]
            }],
            "toolSurface":{},
            "automaticContext":[],
            "agentDeliveries":[{
              "deliveryId":"delivery-one",
              "sourceKind":"worker_result",
              "intent":"information",
              "wakePolicy":"wake",
              "boundary":"next_turn",
              "redelivery":true,
              "provenance":{
                "sourceInvocationId":"worker-run-one",
                "sourceTraceId":"trace-one"
              },
              "content":"The detached worker completed."
            }],
            "environment":{"sha256":"sha256:environment"},
            "systemPromptSha256":"sha256:system",
            "messagesSha256":"sha256:messages",
            "toolsSha256":"sha256:tools",
            "contextSha256":"sha256:context"
          },
          "providerAudit":{"providerRequest":{"kind":"exact_provider_envelope"}},
          "provenanceAvailability":"complete"
        }
        """.utf8)

        let detail = try JSONDecoder().decode(SessionContextRequestDetailDTO.self, from: data)
        let delivery = try #require(detail.contextManifest?.agentDeliveries.first)

        #expect(detail.format == "tron.model_provider_request.v4")
        #expect(delivery.deliveryId == "delivery-one")
        #expect(delivery.sourceKind == "worker_result")
        #expect(delivery.redelivery)
        #expect(delivery.content == "The detached worker completed.")
        let provenance = try #require(delivery.provenance.value as? [String: Any])
        #expect(provenance["sourceInvocationId"] as? String == "worker-run-one")
    }

    @Test("Agent update summaries decode their optional worker identity")
    func agentUpdateSummaryDecodes() throws {
        let data = Data("""
        {
          "updates":[{
            "deliveryId":"delivery-one",
            "status":"pending",
            "sourceKind":"worker_result",
            "sourceWorkerId":"research-curator",
            "sourceWorkerName":"Research Curator",
            "intent":"information",
            "sourceSessionId":"session-one",
            "sourceInvocationId":"worker-run-one",
            "sourceTraceId":"trace-one",
            "resultInvocationId":"worker-run-one",
            "wakePolicy":"passive",
            "boundary":"next_turn",
            "causalDepth":1,
            "redelivery":false,
            "leaseCount":0,
            "wakeAttempts":0,
            "lastError":null,
            "preview":"Three findings are ready.",
            "createdAt":"2026-07-28T07:20:00Z",
            "preparedRunId":null,
            "preparedTurn":null,
            "observedAt":null,
            "cancelledAt":null,
            "expiresAt":null
          }],
          "waits":[]
        }
        """.utf8)

        let result = try JSONDecoder().decode(SessionAgentUpdatesResultDTO.self, from: data)
        let update = try #require(result.updates.first)

        #expect(update.sourceWorkerId == "research-curator")
        #expect(update.sourceWorkerName == "Research Curator")
        #expect(update.preview == "Three findings are ready.")
    }

    @Test("Legacy summaries remain readable without a manifest")
    func legacySummaryDecodes() throws {
        let data = Data("""
        {
          "requests":[{
            "eventId":"legacy-event",
            "sequence":7,
            "timestamp":"2026-07-20T12:00:00Z",
            "format":"tron.model_provider_request.v2",
            "requestClassification":"legacy",
            "messageCount":3,
            "toolCount":4,
            "automaticContextCount":0,
            "manifestAvailable":false,
            "provenanceAvailability":"legacy_unavailable"
          }],
          "hasMore":false,
          "nextBeforeSequence":null
        }
        """.utf8)

        let page = try JSONDecoder().decode(SessionContextRequestsResultDTO.self, from: data)

        #expect(page.requests.first?.manifestAvailable == false)
        #expect(page.requests.first?.provenanceAvailability == "legacy_unavailable")
        #expect(page.requests.first?.instructionCount == nil)
        #expect(page.requests.first?.attachmentMessageCount == nil)
        #expect(page.requests.first?.agentDeliveryCount == nil)
        #expect(page.requests.first?.environmentAvailable == nil)
    }

    @Test("Current summaries decode the lightweight context inventory")
    func currentSummaryInventoryDecodes() throws {
        let data = Data("""
        {
          "requests":[{
            "eventId":"current-event",
            "sequence":8,
            "timestamp":"2026-08-07T12:00:00Z",
            "format":"tron.model_provider_request.v4",
            "requestClassification":"interactive",
            "messageCount":6,
            "toolCount":23,
            "automaticContextCount":1,
            "instructionCount":3,
            "attachmentMessageCount":2,
            "agentDeliveryCount":1,
            "environmentAvailable":true,
            "manifestAvailable":true,
            "provenanceAvailability":"complete"
          }],
          "hasMore":false,
          "nextBeforeSequence":null
        }
        """.utf8)

        let page = try JSONDecoder().decode(SessionContextRequestsResultDTO.self, from: data)
        let summary = try #require(page.requests.first)

        #expect(summary.instructionCount == 3)
        #expect(summary.attachmentMessageCount == 2)
        #expect(summary.agentDeliveryCount == 1)
        #expect(summary.environmentAvailable == true)
    }

    @Test("Worker architecture remains a dynamic 26-node profile projection")
    func dynamicWorkerArchitectureDecodes() throws {
        let nodes: [[String: Any]] = (0..<26).map { index in
            [
                "workerId": "worker-\(index)",
                "name": "Worker \(index)",
                "description": "Owns domain \(index)",
                "activeVersion": "version-\(index)",
                "health": "healthy",
                "modelExposure": index < 18 ? "direct" : "internal",
                "runnerKind": index < 14 ? "agent" : "command",
                "runnerModel": index < 14 ? "gpt-test" : NSNull(),
                "engineHooks": index == 0 ? ["context_summary"] : [],
                "clientActions": index == 1 ? ["speech_transcription"] : [],
                "clientDeliveries": index == 2 ? ["notification_delivery"] : [],
                "triggerKinds": ["manual"],
                "calls": index == 3
                    ? [[
                        "kind": "agent_tool",
                        "label": "worker_4",
                        "targetWorkerId": "worker-4",
                        "responseOwner": NSNull(),
                    ]]
                    : [],
                "presentation": [
                    "suiteId": index == 3 ? "research" : NSNull(),
                    "componentRole": NSNull(),
                    "primary": index == 3,
                ],
                "provenance": [],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: nodes)

        let decoded = try JSONDecoder().decode([WorkerArchitectureNodeDTO].self, from: data)

        #expect(decoded.count == 26)
        #expect(decoded.filter { $0.modelExposure == "direct" }.count == 18)
        #expect(decoded.filter { $0.runnerKind == "agent" }.count == 14)
        #expect(decoded[3].calls.first?.targetWorkerId == "worker-4")
    }
}
