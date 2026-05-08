import Testing
import Foundation

@testable import TronMobile

@Suite("EngineTransport.requireConnection() connection-state guard")
@MainActor
struct EngineTransportConnectionGuardTests {

    // MARK: - Helpers

    private func makeTransport(engineConnectionURL: URL = URL(string: "ws://localhost:8082")!,
                               includeWebSocket: Bool = true,
                               state: ConnectionState = .connected) -> MockEngineTransport {
        let transport = MockEngineTransport()
        if includeWebSocket {
            transport.engineConnection = EngineConnection(serverURL: engineConnectionURL)
        } else {
            transport.engineConnection = nil
        }
        transport.connectionState = state
        return transport
    }

    // MARK: - Tests

    @Test("throws connectionNotEstablished when engineConnection is nil")
    func throwsWhenWebSocketNil() {
        let transport = makeTransport(includeWebSocket: false, state: .connected)
        do {
            _ = try transport.requireConnection()
            Issue.record("expected throw")
        } catch let error as EngineClientError {
            #expect(error == .connectionNotEstablished)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("throws notConnected when state is .disconnected", arguments: [
        ConnectionState.disconnected,
        .connecting,
        .reconnecting(attempt: 1, nextRetrySeconds: 5),
        .deployRestarting(remainingSeconds: 3),
        .failed(reason: "dead")
    ])
    func throwsWhenStateNotConnected(state: ConnectionState) {
        let transport = makeTransport(state: state)
        do {
            _ = try transport.requireConnection()
            Issue.record("expected throw for state \(state)")
        } catch let error as EngineConnectionError {
            #expect(error == EngineConnectionError.notConnected)
        } catch {
            Issue.record("unexpected error type: \(error) for state \(state)")
        }
    }

    @Test("returns engineConnection when state is .connected")
    func returnsWebSocketWhenConnected() throws {
        let transport = makeTransport(state: .connected)
        let ws = try transport.requireConnection()
        #expect(ws === transport.engineConnection)
    }

    @Test("requireSession also respects connection state")
    func requireSessionRespectsState() {
        let transport = makeTransport(state: .disconnected)
        transport.currentSessionId = "sess-1"
        do {
            _ = try transport.requireSession()
            Issue.record("expected throw")
        } catch {
            // Either notConnected (preferred) or noActiveSession; both indicate the call is
            // correctly blocked. Validate at least one of the two:
            if let ws = error as? EngineConnectionError {
                #expect(ws == .notConnected)
            } else if let rpc = error as? EngineClientError {
                #expect(rpc == .noActiveSession || rpc == .connectionNotEstablished)
            } else {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }
}
