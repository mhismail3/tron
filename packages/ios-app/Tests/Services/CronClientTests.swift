import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("CronClient Tests")
struct CronClientTests {

    @Test("listJobs throws when webSocket is nil")
    func listJobsNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = CronClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.listJobs(enabled: nil, tags: nil, workspaceId: nil) }
    }

    @Test("getJob throws when webSocket is nil")
    func getJobNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = CronClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.getJob(jobId: "j1") }
    }

    @Test("createJob throws when webSocket is nil")
    func createJobNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = CronClient(transport: transport)
        let params = CronCreateJobParams(
            name: "test", description: nil, enabled: true,
            schedule: .every(intervalSecs: 60, anchor: nil),
            payload: .shellCommand(command: "echo hi", workingDirectory: nil, timeoutSecs: nil),
            delivery: nil, overlapPolicy: nil, misfirePolicy: nil,
            maxRetries: nil, autoDisableAfter: nil, tags: nil, workspaceId: nil
        )
        await #expect(throws: RPCClientError.self) { _ = try await client.createJob(params) }
    }

    @Test("updateJob throws when webSocket is nil")
    func updateJobNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = CronClient(transport: transport)
        await #expect(throws: RPCClientError.self) {
            _ = try await client.updateJob(jobId: "j1", name: "new name")
        }
    }

    @Test("deleteJob throws when webSocket is nil")
    func deleteJobNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = CronClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.deleteJob(jobId: "j1") }
    }

    @Test("triggerJob throws when webSocket is nil")
    func triggerJobNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = CronClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.triggerJob(jobId: "j1") }
    }

    @Test("getStatus throws when webSocket is nil")
    func getStatusNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = CronClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.getStatus() }
    }

    @Test("getRuns throws when webSocket is nil")
    func getRunsNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = CronClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.getRuns(jobId: "j1", limit: nil, offset: nil, status: nil) }
    }
}
