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
            updatedAt: "2026-07-19T12:00:00Z"
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
            case "worker_kernel::runs":
                #expect((payload as? WorkerRunsRequestDTO)?.limit == 25)
                return WorkerRunsResultDTO(runs: [])
            case "worker_kernel::inbox":
                #expect((payload as? WorkerRunsRequestDTO)?.workerId == "research")
                return WorkerInboxResultDTO(items: [])
            default:
                throw EngineConnectionError.invalidResponse
            }
        }

        _ = try await client.workers()
        _ = try await client.workerRuns(workerId: "research", limit: 25)
        _ = try await client.workerInbox(workerId: "research", limit: 10)

        #expect(functions == [
            "worker_kernel::list",
            "worker_kernel::runs",
            "worker_kernel::inbox",
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
                format: 1,
                autonomousWorkers: true,
                dispatchStopped: false,
                coreComponents: [
                    EngineCoreComponentDTO(
                        id: "worker_runtime",
                        title: "Worker Runtime",
                        role: "Runs workers",
                        category: "kernel",
                        status: "active"
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
                    format: 1,
                    catalogRevision: 42,
                    surfaceHash: "abc123",
                    fixedToolCount: 28,
                    projectedWorkerCount: 1,
                    availableWorkerCount: 3,
                    tools: [
                        EngineSurfaceToolDTO(
                            modelName: "worker_research",
                            functionId: "worker_kernel::dynamic_research",
                            functionRevision: 2,
                            ownerWorker: "worker_kernel",
                            description: "Research recent sources",
                            inputSchema: AnyCodable(["type": "object"]),
                            outputSchema: AnyCodable(["type": "object"]),
                            effectClass: "ExternalSideEffect",
                            risk: "high",
                            exposed: true,
                            workerId: "research",
                            workerVersion: "v2",
                            primitiveGroup: nil,
                            selectionReason: "relevance"
                        )
                    ],
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
        #expect(snapshot.surface.tools.first?.selectionReason == "relevance")
        #expect(snapshot.surface.availableWorkers.first?.projected == true)
        #expect(snapshot.coreComponents.first?.category == "kernel")
        #expect(snapshot.fixedTools.first?.primitiveGroup == "host")
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
                    attemptCount: 1,
                    createdAt: "2026-07-19T12:00:00Z",
                    startedAt: nil,
                    completedAt: "2026-07-19T12:00:01Z"
                )
            case "worker_kernel::disable":
                return worker(enabled: false)
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
        _ = try await client.stopWorker(workerId: "research", idempotencyKey: key)
        _ = try await client.setWorkerEnabled(false, workerId: "research", idempotencyKey: key)
        _ = try await client.setWorkersStopped(true, idempotencyKey: key)

        #expect(functions == [
            "worker_kernel::invoke",
            "worker_kernel::stop",
            "worker_kernel::disable",
            "worker_kernel::stop_all",
        ])
        #expect(!functions.contains { $0.hasPrefix("worker_lifecycle::") })
    }
}
