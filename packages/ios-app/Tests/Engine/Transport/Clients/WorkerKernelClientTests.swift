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
        _ = try await client.setWorkerEnabled(false, workerId: "research", idempotencyKey: key)
        _ = try await client.setWorkersStopped(true, idempotencyKey: key)

        #expect(functions == [
            "worker_kernel::invoke",
            "worker_kernel::disable",
            "worker_kernel::stop_all",
        ])
        #expect(!functions.contains { $0.hasPrefix("worker_lifecycle::") })
    }
}
