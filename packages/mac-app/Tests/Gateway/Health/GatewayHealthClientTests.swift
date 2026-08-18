import Foundation
import Testing
@testable import TronMac

/// Network behavior is covered only at the closed-port boundary; the pure
/// frame decoder owns the cross-language gateway contract assertions.
@Suite("GatewayHealthClient.decodeFrame")
struct GatewayHealthClientDecodeTests {
    @Test("matching system.info response projects the gateway version")
    func matchingCanonicalResponseProjectsVersion() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","piVersion":"0.84.1","capabilities":[]}}"#
        #expect(GatewayHealthClient.decodeFrame(data: Data(body.utf8)) == .result(GatewayHealthInfo(version: "0.1.0")))
    }

    @Test("missing required gateway identity is malformed")
    func missingCanonicalFieldsIsMalformed() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":3,"minProtocolVersion":3,"machineId":""}}"#
        #expect(GatewayHealthClient.decodeFrame(data: Data(body.utf8)) == .malformed)
    }

    @Test("protocol versions must exactly match the supported transport")
    func incompatibleProtocolIsMalformed() {
        let older = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine"}}"#
        let future = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":4,"minProtocolVersion":3,"machineId":"machine"}}"#
        let inverted = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":1,"minProtocolVersion":3,"machineId":"machine"}}"#
        #expect(GatewayHealthClient.decodeFrame(data: Data(older.utf8)) == .malformed)
        #expect(GatewayHealthClient.decodeFrame(data: Data(future.utf8)) == .malformed)
        #expect(GatewayHealthClient.decodeFrame(data: Data(inverted.utf8)) == .malformed)
    }

    @Test("malformed JSON is classified")
    func malformedJSONIsClassified() {
        #expect(GatewayHealthClient.decodeFrame(data: Data("garbage".utf8)) == .malformed)
        #expect(GatewayHealthClient.decodeFrame(data: Data()) == .malformed)
    }

    @Test("hello and unrelated events are ignored")
    func unrelatedFrameIsIgnored() {
        let body = #"{"type":"hello","protocolVersion":3,"machineId":"machine"}"#
        #expect(GatewayHealthClient.decodeFrame(data: Data(body.utf8)) == .ignore)
    }

    @Test("server hello must be exact before system.info is sent")
    func serverHelloRequiresExactTransportVersions() {
        let valid = #"{"type":"hello","protocolVersion":3,"minProtocolVersion":3}"#
        let older = #"{"type":"hello","protocolVersion":2,"minProtocolVersion":2}"#
        let future = #"{"type":"hello","protocolVersion":4,"minProtocolVersion":3}"#
        #expect(GatewayHealthClient.decodeHello(data: Data(valid.utf8)))
        #expect(!GatewayHealthClient.decodeHello(data: Data(older.utf8)))
        #expect(!GatewayHealthClient.decodeHello(data: Data(future.utf8)))
    }

    @Test("system.info responses are not accepted as the server hello")
    func responseCannotSatisfyHelloGate() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine"}}"#
        #expect(!GatewayHealthClient.decodeHello(data: Data(body.utf8)))
        #expect(GatewayHealthClient.decodeFrame(data: Data(body.utf8)) == .result(GatewayHealthInfo(version: "0.1.0")))
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
