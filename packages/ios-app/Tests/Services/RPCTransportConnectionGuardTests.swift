import Testing
import Foundation

@testable import TronMobile

@Suite("RPCTransport.requireConnection() connection-state guard")
@MainActor
struct RPCTransportConnectionGuardTests {

    // MARK: - Helpers

    private func makeTransport(webSocketURL: URL = URL(string: "ws://localhost:8082")!,
                               includeWebSocket: Bool = true,
                               state: ConnectionState = .connected) -> MockRPCTransport {
        let transport = MockRPCTransport()
        if includeWebSocket {
            transport.webSocket = WebSocketService(serverURL: webSocketURL)
        } else {
            transport.webSocket = nil
        }
        transport.connectionState = state
        return transport
    }

    // MARK: - Tests

    @Test("throws connectionNotEstablished when webSocket is nil")
    func throwsWhenWebSocketNil() {
        let transport = makeTransport(includeWebSocket: false, state: .connected)
        do {
            _ = try transport.requireConnection()
            Issue.record("expected throw")
        } catch let error as RPCClientError {
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
        } catch let error as WebSocketError {
            #expect(error == WebSocketError.notConnected)
        } catch {
            Issue.record("unexpected error type: \(error) for state \(state)")
        }
    }

    @Test("returns webSocket when state is .connected")
    func returnsWebSocketWhenConnected() throws {
        let transport = makeTransport(state: .connected)
        let ws = try transport.requireConnection()
        #expect(ws === transport.webSocket)
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
            if let ws = error as? WebSocketError {
                #expect(ws == .notConnected)
            } else if let rpc = error as? RPCClientError {
                #expect(rpc == .noActiveSession || rpc == .connectionNotEstablished)
            } else {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }
}
