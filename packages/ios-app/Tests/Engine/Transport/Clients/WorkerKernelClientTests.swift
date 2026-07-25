import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("WorkerKernelClient Tests")
struct WorkerKernelClientTests {
    private func connectedTransport() -> MockEngineTransport {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:9847/engine")!
        )
        return transport
    }

    private func worker(enabled: Bool = true) -> WorkerSummaryDTO {
        WorkerSummaryDTO(
            workerId: "research",
            name: "Research",
            description: "Research worker",
            toolName: "research",
            runnerKind: "command",
            activeVersion: "v1",
            enabled: enabled,
            retired: false,
            health: "healthy",
            triggerCount: 1,
            updatedAt: "2026-07-19T12:00:00Z",
            presentation: nil
        )
    }

    @Test("Worker reads use only worker-kernel functions")
    func readsUseWorkerKernelFunctions() async throws {
        let transport = connectedTransport()
        let client = WorkerKernelClient(transport: transport)
        var functions: [String] = []

        transport.readHandler = { functionId, payload, _ in
            functions.append(functionId.rawValue)
            switch functionId.rawValue {
            case "worker_kernel::list":
                #expect((payload as? WorkerListRequestDTO)?.includeRetired == true)
                return WorkerListResultDTO(workers: [worker()], stopAll: false)
            case "worker_kernel::inspect":
                #expect((payload as? WorkerInspectRequestDTO)?.workerId == "research")
                #expect((payload as? WorkerInspectRequestDTO)?.detail == "full")
                return WorkerInspectResultDTO(
                    worker: worker(),
                    bundle: [:],
                    versions: [],
                    triggers: [],
                    audit: [],
                    versionDirectory: "/workers/research/v1"
                )
            case "worker_kernel::runs":
                #expect((payload as? WorkerRunsRequestDTO)?.limit == 25)
                #expect((payload as? WorkerRunsRequestDTO)?.offset == 40)
                #expect((payload as? WorkerRunsRequestDTO)?.originSessionId == "sess_origin")
                #expect((payload as? WorkerRunsRequestDTO)?.detail == "full")
                return WorkerRunsResultDTO(runs: [])
            case "worker_kernel::inbox":
                #expect((payload as? WorkerInboxRequestDTO)?.workerId == "research")
                #expect((payload as? WorkerInboxRequestDTO)?.offset == 20)
                #expect((payload as? WorkerInboxRequestDTO)?.detail == "full")
                #expect((payload as? WorkerInboxRequestDTO)?.attentionOnly == true)
                return WorkerInboxResultDTO(items: [])
            default:
                throw EngineConnectionError.invalidResponse
            }
        }

        _ = try await client.workers()
        _ = try await client.inspectWorker("research")
        _ = try await client.workerRuns(
            workerId: "research",
            originSessionId: "sess_origin",
            limit: 25,
            offset: 40
        )
        _ = try await client.workerInbox(
            workerId: "research",
            limit: 10,
            offset: 20,
            attentionOnly: true
        )

        #expect(functions == [
            "worker_kernel::list",
            "worker_kernel::inspect",
            "worker_kernel::runs",
            "worker_kernel::inbox",
        ])
    }

    @Test("Worker graph lookup preserves exact durable association filters")
    func graphLookupUsesExactFilters() async throws {
        let transport = connectedTransport()
        let client = WorkerKernelClient(transport: transport)
        var requests: [WorkerRunsRequestDTO] = []

        transport.readHandler = { functionId, payload, _ in
            #expect(functionId.rawValue == "worker_kernel::runs")
            requests.append(try #require(payload as? WorkerRunsRequestDTO))
            return WorkerRunsResultDTO(detail: "graph", runs: [], graphs: [])
        }

        _ = try await client.workerRunGraph(invocationId: "run-1")
        _ = try await client.workerRunGraph(modelToolInvocationId: "tool-1")
        _ = try await client.workerRunGraphs(
            originSessionId: "sess-origin",
            limit: 10,
            offset: 10
        )

        #expect(requests.count == 3)
        #expect(requests[0].invocationId == "run-1")
        #expect(requests[0].modelToolInvocationId == nil)
        #expect(requests[0].detail == "graph")
        #expect(requests[0].limit == 1)
        #expect(requests[1].invocationId == nil)
        #expect(requests[1].modelToolInvocationId == "tool-1")
        #expect(requests[2].originSessionId == "sess-origin")
        #expect(requests[2].detail == "graph")
        #expect(requests[2].limit == 10)
        #expect(requests[2].offset == 10)
    }

    @Test("Exact worker result reads preserve bounded pointer and paging")
    func resultReadUsesBoundedKernelOperation() async throws {
        let transport = connectedTransport()
        let client = WorkerKernelClient(transport: transport)

        transport.readHandler = { functionId, payload, _ in
            #expect(functionId.rawValue == "worker_kernel::result_read")
            let request = try #require(payload as? WorkerResultReadRequestDTO)
            #expect(request.invocationId == "run-1")
            #expect(request.pointer == "/claims")
            #expect(request.offset == 20)
            #expect(request.limit == 20)
            return WorkerResultChunkDTO(
                kind: "worker_result_chunk",
                reference: WorkerResultReferenceDTO(
                    kind: "worker_result_reference",
                    invocationId: "run-1",
                    workerId: "research",
                    workerVersion: "v1",
                    outputSchemaSha256: "sha256:" + String(repeating: "a", count: 64),
                    contentSha256: "sha256:" + String(repeating: "b", count: 64),
                    sizeBytes: 12_000,
                    preview: "Research result",
                    message: "Stored durably"
                ),
                pointer: "/claims",
                value: AnyCodable([]),
                children: [],
                offset: 20,
                returned: 0,
                total: 20,
                nextOffset: nil,
                truncated: false
            )
        }

        let result = try await client.workerResult(
            invocationId: "run-1",
            pointer: "/claims",
            offset: 20,
            limit: 99
        )

        #expect(result.reference.invocationId == "run-1")
        #expect(result.reference.sizeBytes == 12_000)
    }

    @Test("Worker run controls map to generic durable kernel operations")
    func runControlsUseGenericKernelOperations() async throws {
        let transport = connectedTransport()
        let client = WorkerKernelClient(transport: transport)
        let key = EngineIdempotencyKey.userAction("run-controls")
        var functions: [String] = []

        func invocation(status: String, mode: String) -> WorkerInvocationDTO {
            WorkerInvocationDTO(
                invocationId: "run-1",
                workerId: "research",
                workerVersion: "v1",
                status: status,
                input: AnyCodable(["query": "Tron"]),
                output: nil,
                error: nil,
                idempotencyKey: key.rawValue,
                traceId: "trace-1",
                causalDepth: 0,
                triggerKind: "manual",
                originSessionId: "sess-origin",
                agentSessionId: nil,
                interactionMode: mode,
                attemptCount: 1,
                createdAt: "2026-07-24T12:00:00Z",
                startedAt: "2026-07-24T12:00:00Z",
                completedAt: nil
            )
        }

        transport.readHandler = { functionId, payload, _ in
            functions.append(functionId.rawValue)
            #expect(functionId.rawValue == "worker_kernel::await")
            let request = try #require(payload as? WorkerAwaitRequestDTO)
            #expect(request.invocationId == "run-1")
            #expect(request.timeoutSeconds == 10)
            return WorkerAwaitResultDTO(
                invocation: invocation(status: "running", mode: "background"),
                timedOut: true
            )
        }
        transport.writeHandler = { functionId, payload, receivedKey, _ in
            functions.append(functionId.rawValue)
            #expect(receivedKey == key)
            switch functionId.rawValue {
            case "worker_kernel::detach":
                #expect((payload as? WorkerCancelRequestDTO)?.invocationId == "run-1")
                return invocation(status: "running", mode: "background")
            case "worker_kernel::invoke":
                let retry = try #require(payload as? WorkerRetryRequestDTO)
                #expect(retry.retryOfInvocationId == "run-1")
                #expect(retry.mode == .wait)
                return invocation(status: "queued", mode: "background")
            default:
                throw EngineConnectionError.invalidResponse
            }
        }

        _ = try await client.detachWorkerInvocation(invocationId: "run-1", idempotencyKey: key)
        _ = try await client.awaitWorkerInvocation(invocationId: "run-1", timeoutSeconds: 20)
        _ = try await client.retryWorkerInvocation(invocationId: "run-1", idempotencyKey: key)

        #expect(functions == [
            "worker_kernel::detach",
            "worker_kernel::await",
            "worker_kernel::invoke",
        ])
    }

    @Test("Engine surface introspection is typed and session scoped")
    func engineSurfaceIntrospectionIsTypedAndSessionScoped() async throws {
        let transport = connectedTransport()
        let client = WorkerKernelClient(transport: transport)
        transport.readHandler = { functionId, payload, options in
            #expect(functionId.rawValue == "engine::surface_snapshot")
            #expect((payload as? EngineSurfaceSnapshotRequestDTO)?.relevanceQuery == "research")
            #expect(options.context?.sessionId == "session-1")
            return EngineIntrospectionSnapshotDTO(
                dispatchStopped: false,
                activeEngineHooks: [
                    EngineHookOwnerDTO(
                        hook: "context_summary",
                        workerId: "summary-worker",
                        workerVersion: "v-summary"
                    )
                ],
                activeClientActions: [
                    ClientActionOwnerDTO(
                        action: "speech_transcription",
                        workerId: "speech-worker",
                        workerVersion: "speech-v1"
                    )
                ],
                fixedTools: [
                    EngineSurfaceToolDTO(
                        modelName: "filesystem_read",
                        functionId: "worker_kernel::filesystem_read",
                        functionRevision: 1,
                        ownerWorker: "worker_kernel",
                        description: "Read a local file",
                        inputSchema: AnyCodable(["type": "object"]),
                        outputSchema: AnyCodable(["type": "object"]),
                        effectClass: "PureRead",
                        risk: "low",
                        exposed: true,
                        workerId: nil,
                        workerVersion: nil,
                        primitiveGroup: "host",
                        selectionReason: "fixed"
                    )
                ],
                surface: AgentToolSurfaceDTO(
                    catalogRevision: 42,
                    surfaceHash: "abc123",
                    fixedToolCount: 29,
                    projectedWorkerCount: 1,
                    availableWorkerCount: 3,
                    availableWorkers: [
                        AvailableWorkerToolDTO(
                            workerId: "research",
                            modelName: "worker_research",
                            functionId: "worker_kernel::dynamic_research",
                            functionRevision: 2,
                            workerVersion: "v2",
                            promoted: false,
                            projected: true,
                            selectionReason: "relevance",
                            relevanceScore: 1,
                            completedRuns: 3
                        )
                    ]
                ),
                workers: [worker()]
            )
        }

        let snapshot = try await client.engineSurfaceSnapshot(
            sessionId: "session-1",
            relevanceQuery: "research"
        )

        #expect(snapshot.surface.catalogRevision == 42)
        #expect(snapshot.surface.availableWorkers.first?.projected == true)
        #expect(snapshot.fixedTools.first?.primitiveGroup == "host")
        #expect(snapshot.activeEngineHooks.first?.workerId == "summary-worker")
        #expect(snapshot.activeClientActions.first?.workerId == "speech-worker")
        #expect(snapshot.workers.first?.workerId == "research")
    }

    @Test("Worker writes use direct kernel functions and explicit idempotency")
    func writesUseDirectKernelFunctions() async throws {
        let transport = connectedTransport()
        let client = WorkerKernelClient(transport: transport)
        var functions: [String] = []
        let key = EngineIdempotencyKey.userAction("worker-kernel-test")

        transport.writeHandler = { functionId, payload, receivedKey, _ in
            functions.append(functionId.rawValue)
            #expect(receivedKey == key)
            switch functionId.rawValue {
            case "worker_kernel::invoke":
                let request = try #require(payload as? WorkerInvokeRequestDTO)
                #expect(request.workerId == "research")
                #expect(request.idempotencyKey == key.rawValue)
                #expect(request.mode == (functions.count == 1 ? .wait : .enqueue))
                return WorkerInvocationDTO(
                    invocationId: "run-1",
                    workerId: "research",
                    workerVersion: "v1",
                    status: "completed",
                    input: request.input,
                    output: AnyCodable(["ok": true]),
                    error: nil,
                    idempotencyKey: key.rawValue,
                    traceId: "trace-1",
                    causalDepth: 0,
                    triggerKind: "manual",
                    originSessionId: nil,
                    agentSessionId: nil,
                    attemptCount: 1,
                    createdAt: "2026-07-19T12:00:00Z",
                    startedAt: nil,
                    completedAt: "2026-07-19T12:00:01Z"
                )
            case "worker_kernel::disable":
                return worker(enabled: false)
            case "worker_kernel::cancel":
                #expect((payload as? WorkerCancelRequestDTO)?.invocationId == "run-1")
                return WorkerInvocationDTO(
                    invocationId: "run-1",
                    workerId: "research",
                    workerVersion: "v1",
                    status: "cancelled",
                    input: AnyCodable(["query": "Tron"]),
                    output: nil,
                    error: "worker invocation cancelled explicitly",
                    idempotencyKey: key.rawValue,
                    traceId: "trace-1",
                    causalDepth: 0,
                    triggerKind: "manual",
                    originSessionId: nil,
                    agentSessionId: nil,
                    attemptCount: 1,
                    createdAt: "2026-07-19T12:00:00Z",
                    startedAt: nil,
                    completedAt: "2026-07-19T12:00:01Z"
                )
            case "worker_kernel::stop":
                return worker(enabled: true)
            case "worker_kernel::stop_all":
                #expect((payload as? WorkerStopAllRequestDTO)?.stopped == true)
                return WorkerStopAllResultDTO(stopped: true)
            default:
                throw EngineConnectionError.invalidResponse
            }
        }

        _ = try await client.invokeWorker(
            workerId: "research",
            input: AnyCodable(["query": "Tron"]),
            idempotencyKey: key
        )
        _ = try await client.invokeWorker(
            workerId: "research",
            input: AnyCodable(["query": "Tron"]),
            idempotencyKey: key,
            mode: .enqueue
        )
        _ = try await client.cancelWorkerInvocation(invocationId: "run-1", idempotencyKey: key)
        _ = try await client.stopWorker(workerId: "research", idempotencyKey: key)
        _ = try await client.setWorkerEnabled(false, workerId: "research", idempotencyKey: key)
        _ = try await client.setWorkersStopped(true, idempotencyKey: key)

        #expect(functions == [
            "worker_kernel::invoke",
            "worker_kernel::invoke",
            "worker_kernel::cancel",
            "worker_kernel::stop",
            "worker_kernel::disable",
            "worker_kernel::stop_all",
        ])
        #expect(!functions.contains { $0.hasPrefix("worker_lifecycle::") })
    }

    @Test("Session-origin worker invocation carries authenticated session context")
    func sessionOriginInvocationCarriesSessionContext() async throws {
        let transport = connectedTransport()
        let client = WorkerKernelClient(transport: transport)
        let key = EngineIdempotencyKey.userAction("speech-transcription-test")

        transport.writeHandler = { functionId, payload, receivedKey, options in
            #expect(functionId.rawValue == "worker_kernel::invoke")
            #expect((payload as? WorkerInvokeRequestDTO)?.workerId == "speech-worker")
            #expect(receivedKey == key)
            #expect(options.context?.sessionId == "session-voice")
            return WorkerInvocationDTO(
                invocationId: "run-voice",
                workerId: "speech-worker",
                workerVersion: "v1",
                status: "completed",
                input: AnyCodable(["audioBase64": "AA==", "mimeType": "audio/wav", "fileName": "voice.wav"]),
                output: AnyCodable(["text": "hello"]),
                error: nil,
                idempotencyKey: key.rawValue,
                traceId: "trace-voice",
                causalDepth: 0,
                triggerKind: "manual",
                originSessionId: "session-voice",
                agentSessionId: nil,
                attemptCount: 1,
                createdAt: "2026-07-23T12:00:00Z",
                startedAt: "2026-07-23T12:00:00Z",
                completedAt: "2026-07-23T12:00:01Z"
            )
        }

        let invocation = try await client.invokeWorker(
            workerId: "speech-worker",
            input: AnyCodable(["audioBase64": "AA==", "mimeType": "audio/wav", "fileName": "voice.wav"]),
            idempotencyKey: key,
            originSessionId: "session-voice"
        )

        #expect(invocation.output?.legacyInline?.dictionaryValue?["text"] as? String == "hello")
    }
}
