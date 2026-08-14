import Foundation
import Testing
@testable import TronMac

/// Network behavior is covered only at the closed-port boundary; the pure
/// frame decoder owns the cross-language gateway contract assertions.
@Suite("GatewayHealthClient.decodeFrame")
struct GatewayHealthClientDecodeTests {
    @Test("matching system.info response projects the gateway version")
    func matchingCanonicalResponseProjectsVersion() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","piVersion":"0.84.1","capabilities":[]}}"#
        #expect(GatewayHealthClient.decodeFrame(data: Data(body.utf8)) == .result(GatewayHealthInfo(version: "0.1.0")))
    }

    @Test("missing required gateway identity is malformed")
    func missingCanonicalFieldsIsMalformed() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":2,"minProtocolVersion":2,"machineId":""}}"#
        #expect(GatewayHealthClient.decodeFrame(data: Data(body.utf8)) == .malformed)
    }

    @Test("inverted protocol range is malformed")
    func incompatibleProtocolIsMalformed() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":1,"minProtocolVersion":2,"machineId":"machine"}}"#
        #expect(GatewayHealthClient.decodeFrame(data: Data(body.utf8)) == .malformed)
    }

    @Test("malformed JSON is classified")
    func malformedJSONIsClassified() {
        #expect(GatewayHealthClient.decodeFrame(data: Data("garbage".utf8)) == .malformed)
        #expect(GatewayHealthClient.decodeFrame(data: Data()) == .malformed)
    }

    @Test("hello and unrelated events are ignored")
    func unrelatedFrameIsIgnored() {
        let body = #"{"type":"hello","protocolVersion":2,"machineId":"machine"}"#
        #expect(GatewayHealthClient.decodeFrame(data: Data(body.utf8)) == .ignore)
    }

    @Test("matching gateway error frame is not a heartbeat")
    func gatewayErrorFrameIsError() {
        let body = #"{"type":"response","id":"mac-system-info","ok":false,"error":{"code":"invalid_request","message":"invalid id"}}"#
        #expect(GatewayHealthClient.decodeFrame(data: Data(body.utf8)) == .error)
    }
}

@Suite("GatewayHealthResult")
struct GatewayHealthResultTests {
    @Test("equality holds for matching cases")
    func equality() {
        #expect(GatewayHealthResult.unauthorized == GatewayHealthResult.unauthorized)
        #expect(GatewayHealthResult.unreachable == GatewayHealthResult.unreachable)
        #expect(GatewayHealthResult.unauthorized != GatewayHealthResult.unreachable)
    }
}

@Suite("GatewayHealthClient — live network classification")
struct GatewayHealthClientLiveTests {
    @Test("closed port is never reported as authenticated")
    func closedPortIsUnreachable() async throws {
        let result = await GatewayHealthClient.ping(host: "127.0.0.1", port: 1, token: "anything", timeout: 1)
        switch result {
        case .unreachable, .timeout: break
        case .success, .unauthorized, .malformedResponse:
            Issue.record("expected .unreachable/.timeout for closed port, got \(result)")
        }
    }
}
