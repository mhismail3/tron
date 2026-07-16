import Foundation
import Testing
@testable import TronMac

/// Tests for the engine protocol frame decoder behind `ServerPing`. The
/// network ping itself is not unit-tested (URLSession mocking is
/// expensive); we cover the decode path which is where every
/// JSON-shape edge lives.
@Suite("ServerPing.decodeFrame")
struct ServerPingDecodeTests {
    @Test("matching response projects the full server result")
    func matchingResponseProjectsServerInfo() {
        let body = """
        {"type":"response","id":"mac-system-ping","ok":true,"result":{"child":{"value":{"serverVersion":"0.5.0","port":9847,"tailscaleIp":"100.64.0.1","paired":true}}}}
        """
        let expected = ServerInfo(version: "0.5.0", port: 9847, tailscaleIp: "100.64.0.1", paired: true)
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .result(expected))
    }

    @Test("missing optional fields use defaults")
    func missingOptionalFields() {
        let body = """
        {"type":"response","id":"mac-system-ping","ok":true,"result":{"child":{"value":{}}}}
        """
        let expected = ServerInfo(
            version: "",
            port: TronPaths.defaultServerPort,
            tailscaleIp: nil,
            paired: false
        )
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .result(expected))
    }

    @Test("malformed JSON is classified")
    func malformedJSONIsClassified() {
        #expect(ServerPing.decodeFrame(data: Data("garbage".utf8)) == .malformed)
        #expect(ServerPing.decodeFrame(data: Data()) == .malformed)
    }

    @Test("connection.established event is ignored while waiting for ping response")
    func connectionEstablishedIsIgnored() {
        let body = """
        {"type":"connection.established","timestamp":"2026-04-24T17:40:42Z","data":{"clientId":"abc"}}
        """
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .ignore)
    }

    @Test("matching engine protocol error frame is not mistaken for a heartbeat")
    func engineErrorFrameIsError() {
        let body = """
        {"type":"response","id":"mac-system-ping","ok":false,"error":{"code":"INVALID_PARAMS","message":"invalid id"}}
        """
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .error)
    }
}

@Suite("ServerPingResult")
struct ServerPingResultTests {
    @Test("equality holds for matching cases")
    func equality() {
        #expect(ServerPingResult.unauthorized == ServerPingResult.unauthorized)
        #expect(ServerPingResult.unreachable == ServerPingResult.unreachable)
        #expect(ServerPingResult.unauthorized != ServerPingResult.unreachable)
    }
}

/// Tests that the live `ServerPing.ping` correctly classifies network
/// failures. We can't simulate every URLError code without real
/// fixtures, but we can hit a closed port to confirm the
/// `.unreachable` mapping.
@Suite("ServerPing — live network classification")
struct ServerPingLiveTests {
    @Test("ping against a closed port returns .unreachable, never falsely .unauthorized")
    func closedPortIsUnreachable() async throws {
        // Port 1 is reserved + always closed on the loopback interface.
        let result = await ServerPing.ping(host: "127.0.0.1", port: 1, token: "anything", timeout: 1)
        switch result {
        case .unreachable, .timeout:
            // Either is correct — loopback connect refuses immediately
            // on most systems but timeout is acceptable too.
            break
        case .success, .unauthorized, .malformedResponse:
            Issue.record("expected .unreachable/.timeout for closed port, got \(result)")
        }
    }
}
