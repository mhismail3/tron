import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("JobClient Tests")
struct JobClientTests {

    @Test("background throws when webSocket is nil")
    func backgroundNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = JobClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.background(jobId: "j1", sessionId: "s1") }
    }

    @Test("cancel throws when webSocket is nil")
    func cancelNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = JobClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.cancel(jobId: "j1", sessionId: "s1") }
    }

    @Test("subscribe throws when webSocket is nil")
    func subscribeNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = JobClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.subscribe(jobId: "j1", sessionId: "s1") }
    }

    @Test("unsubscribe throws when webSocket is nil")
    func unsubscribeNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = JobClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.unsubscribe(jobId: "j1") }
    }
}
