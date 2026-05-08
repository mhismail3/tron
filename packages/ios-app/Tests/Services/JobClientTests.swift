import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("JobClient Tests")
struct JobClientTests {

    @Test("background throws when engineConnection is nil")
    func backgroundNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = JobClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.background(jobId: "j1", sessionId: "s1", idempotencyKey: .userAction("job.background.test"))
        }
    }

    @Test("cancel throws when engineConnection is nil")
    func cancelNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = JobClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.cancel(jobId: "j1", sessionId: "s1", idempotencyKey: .userAction("job.cancel.test"))
        }
    }

    @Test("subscribe throws when engineConnection is nil")
    func subscribeNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = JobClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.subscribe(jobId: "j1", sessionId: "s1", idempotencyKey: .userAction("job.subscribe.test"))
        }
    }

    @Test("unsubscribe throws when engineConnection is nil")
    func unsubscribeNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = JobClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.unsubscribe(jobId: "j1", idempotencyKey: .userAction("job.unsubscribe.test"))
        }
    }
}
