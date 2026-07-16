import Foundation
import Testing
@testable import TronMac

/// Tests for the engine protocol frame decoder behind `ServerPing`. The
/// network ping itself is not unit-tested (URLSession mocking is
/// expensive); we cover the decode path which is where every
/// JSON-shape edge lives.
@Suite("ServerPing.decodeFrame")
struct ServerPingDecodeTests {
    @Test("matching canonical response projects the server version")
    func matchingCanonicalResponseProjectsServerVersion() {
        let body = """
        {"type":"response","id":"mac-system-ping","ok":true,"result":{"child":{"value":{"pong":true,"timestamp":"2026-07-16T00:00:00.000Z","serverVersion":"0.5.0","serverProtocolVersion":1,"minClientProtocolVersion":1,"compatible":true}}}}
        """
        let expected = ServerPingInfo(version: "0.5.0")
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .result(expected))
    }

    @Test("missing canonical ping fields is malformed")
    func missingCanonicalFieldsIsMalformed() {
        let body = """
        {"type":"response","id":"mac-system-ping","ok":true,"result":{"child":{"value":{}}}}
        """
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .malformed)
    }

    @Test("false pong or compatibility is malformed")
    func falsePongOrCompatibilityIsMalformed() {
        let falsePong = """
        {"type":"response","id":"mac-system-ping","ok":true,"result":{"child":{"value":{"pong":false,"timestamp":"2026-07-16T00:00:00.000Z","serverVersion":"0.5.0","serverProtocolVersion":1,"minClientProtocolVersion":1,"compatible":true}}}}
        """
        let incompatible = falsePong
            .replacingOccurrences(of: "\"pong\":false", with: "\"pong\":true")
            .replacingOccurrences(of: "\"compatible\":true", with: "\"compatible\":false")

        #expect(ServerPing.decodeFrame(data: Data(falsePong.utf8)) == .malformed)
        #expect(ServerPing.decodeFrame(data: Data(incompatible.utf8)) == .malformed)
    }

    @Test("numeric booleans and boolean protocol versions are malformed")
    func bridgedJSONScalarTypesAreMalformed() {
        let numericBooleans = """
        {"type":"response","id":"mac-system-ping","ok":1,"result":{"child":{"value":{"pong":1,"timestamp":"2026-07-16T00:00:00.000Z","serverVersion":"0.5.0","serverProtocolVersion":1,"minClientProtocolVersion":1,"compatible":1}}}}
        """
        let booleanProtocols = """
        {"type":"response","id":"mac-system-ping","ok":true,"result":{"child":{"value":{"pong":true,"timestamp":"2026-07-16T00:00:00.000Z","serverVersion":"0.5.0","serverProtocolVersion":true,"minClientProtocolVersion":false,"compatible":true}}}}
        """

        #expect(ServerPing.decodeFrame(data: Data(numericBooleans.utf8)) == .malformed)
        #expect(ServerPing.decodeFrame(data: Data(booleanProtocols.utf8)) == .malformed)
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
