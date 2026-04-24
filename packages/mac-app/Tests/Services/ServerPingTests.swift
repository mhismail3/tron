import Foundation
import Testing
@testable import TronMac

/// Tests for the JSON-RPC response decoder behind `ServerPing`. The
/// network ping itself is not unit-tested (URLSession mocking is
/// expensive); we cover the decode path which is where every
/// JSON-shape edge lives.
@Suite("ServerPing.decode")
struct ServerPingDecodeTests {
    @Test("happy path: full result object")
    func happyDecode() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"result":{"serverVersion":"0.5.0","port":9847,"tailscaleIp":"100.64.0.1","paired":true}}
        """
        let info = try #require(ServerPing.decode(data: Data(body.utf8)))
        #expect(info.version == "0.5.0")
        #expect(info.port == 9847)
        #expect(info.tailscaleIp == "100.64.0.1")
        #expect(info.paired == true)
    }

    @Test("missing optional fields fall back to defaults")
    func missingOptionalFields() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"result":{}}
        """
        let info = try #require(ServerPing.decode(data: Data(body.utf8)))
        #expect(info.version == "")
        #expect(info.port == TronPaths.defaultServerPort)
        #expect(info.tailscaleIp == nil)
        #expect(info.paired == false)
    }

    @Test("error response (no result) returns nil")
    func errorResponseReturnsNil() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}
        """
        #expect(ServerPing.decode(data: Data(body.utf8)) == nil)
    }

    @Test("malformed JSON returns nil")
    func malformedJSONReturnsNil() throws {
        #expect(ServerPing.decode(data: Data("garbage".utf8)) == nil)
        #expect(ServerPing.decode(data: Data()) == nil)
    }

    @Test("paired defaults to false when field is missing")
    func pairedDefaults() throws {
        let body = """
        {"result":{"serverVersion":"0.5.0","port":1234}}
        """
        let info = try #require(ServerPing.decode(data: Data(body.utf8)))
        #expect(info.paired == false)
    }

    @Test("response frame decodes string-id server response")
    func responseFrameDecodesStringID() {
        let body = """
        {"id":"mac-system-ping","success":true,"result":{"serverVersion":"0.5.0","port":9847,"tailscaleIp":"100.64.0.1","paired":true}}
        """
        let expected = ServerInfo(version: "0.5.0", port: 9847, tailscaleIp: "100.64.0.1", paired: true)
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .result(expected))
    }

    @Test("connection.established event is ignored while waiting for ping response")
    func connectionEstablishedIsIgnored() {
        let body = """
        {"type":"connection.established","timestamp":"2026-04-24T17:40:42Z","data":{"clientId":"abc"}}
        """
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .ignore)
    }

    @Test("matching RPC error frame is not mistaken for a heartbeat")
    func rpcErrorFrameIsError() {
        let body = """
        {"id":"mac-system-ping","success":false,"error":{"code":"INVALID_PARAMS","message":"invalid id"}}
        """
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .error)
    }
}

@Suite("PermissionProbeRPC.decodeFrame")
struct PermissionProbeRPCDecodeFrameTests {
    @Test("connection.established event is ignored while waiting for permissions response")
    func connectionEstablishedIsIgnored() {
        let body = """
        {"type":"connection.established","timestamp":"2026-04-24T17:40:42Z","data":{"clientId":"abc"}}
        """
        #expect(PermissionProbeRPC.decodeFrame(Data(body.utf8)) == .ignore)
    }

    @Test("string-id permissions response decodes statuses")
    func stringIDResponseDecodesStatuses() {
        let body = """
        {"id":"mac-probe-permissions","success":true,"result":{"fullDiskAccess":"granted","screenRecording":"denied","accessibility":"unknown"}}
        """
        #expect(PermissionProbeRPC.decodeFrame(Data(body.utf8)) == .result([
            .fullDiskAccess: .granted,
            .screenRecording: .denied,
            .accessibility: .probeUnavailable,
        ]))
    }

    @Test("matching permissions RPC error frame is not decoded as statuses")
    func rpcErrorFrameIsError() {
        let body = """
        {"id":"mac-probe-permissions","success":false,"error":{"code":"NOPE","message":"nope"}}
        """
        #expect(PermissionProbeRPC.decodeFrame(Data(body.utf8)) == .error)
    }
}

@Suite("ServerPingResult")
struct ServerPingResultTests {
    @Test("info accessor returns nil for non-success cases")
    func infoAccessorNilForFailures() {
        #expect(ServerPingResult.unauthorized.info == nil)
        #expect(ServerPingResult.unreachable.info == nil)
        #expect(ServerPingResult.timeout.info == nil)
        #expect(ServerPingResult.malformedResponse.info == nil)
    }

    @Test("info accessor returns the wrapped ServerInfo on success")
    func infoAccessorSuccess() throws {
        let info = ServerInfo(version: "0.5.0", port: 9847, tailscaleIp: "100.64.0.1", paired: true)
        let result = ServerPingResult.success(info)
        #expect(result.info?.version == "0.5.0")
        #expect(result.info?.port == 9847)
    }

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
