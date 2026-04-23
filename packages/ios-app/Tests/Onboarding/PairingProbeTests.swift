import Foundation
import Testing
@testable import TronMobile

/// `PairingProbe` is the one-shot reachability check the onboarding
/// PairingStep runs before committing the new bearer token + preset.
///
/// The production probe is `URLSessionPairingProbe`, which opens a single
/// WebSocket upgrade to `ws://<host>:<port>/ws` carrying
/// `Authorization: Bearer <token>`, sends a `system.ping` JSON-RPC frame,
/// and classifies the outcome. Tests focus on the **pure** parts of that
/// pipeline:
///
///   1. `urlString(host:port:)` URL formatting (host with `:` for IPv6,
///      hostname vs IP, default port).
///   2. `pingRequestData(protocolVersion:clientVersion:)` JSON encoding
///      (matches what the server's `PingHandler` consumes, lines 45–55 of
///      `packages/agent/src/server/rpc/handlers/system.rs`).
///   3. `classify(envelope:)` outcome mapping for the four shapes:
///      success / unauthorized / incompatible / unreachable.
///
/// The actual WebSocket round-trip is verified end-to-end in
/// `OnboardingFlowUITests` against a stub server — unit tests here are
/// fast and don't need a network.
@Suite("PairingProbe")
struct PairingProbeTests {

    // MARK: - URL formatting

    @Test("urlString(): builds ws scheme with host and port")
    func urlStringBasic() {
        let url = URLSessionPairingProbe.urlString(host: "100.64.0.7", port: 9847)
        #expect(url == "ws://100.64.0.7:9847/ws")
    }

    @Test("urlString(): hostname (MagicDNS) works the same as an IP")
    func urlStringHostname() {
        let url = URLSessionPairingProbe.urlString(host: "mac-name.tail-scale.ts.net", port: 9847)
        #expect(url == "ws://mac-name.tail-scale.ts.net:9847/ws")
    }

    @Test("urlString(): IPv6 literal gets bracketed")
    func urlStringIPv6() {
        let url = URLSessionPairingProbe.urlString(host: "fd7a:115c:a1e0::1", port: 9847)
        #expect(url == "ws://[fd7a:115c:a1e0::1]:9847/ws",
                "IPv6 literals must be wrapped in brackets per RFC 3986")
    }

    @Test("urlString(): non-default port is preserved verbatim")
    func urlStringCustomPort() {
        let url = URLSessionPairingProbe.urlString(host: "h", port: 9000)
        #expect(url == "ws://h:9000/ws")
    }

    // MARK: - Ping payload

    @Test("pingRequestData(): produces a JSON-RPC ping with protocolVersion + clientVersion")
    func pingPayloadShape() throws {
        let data = URLSessionPairingProbe.pingRequestData(
            protocolVersion: 1,
            clientVersion: "1.2.3",
            requestId: "req-1"
        )
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["id"] as? String == "req-1")
        #expect(parsed?["method"] as? String == "system.ping")
        let params = parsed?["params"] as? [String: Any]
        #expect(params?["protocolVersion"] as? Int == 1)
        #expect(params?["clientVersion"] as? String == "1.2.3")
    }

    // MARK: - Classification

    @Test("classify(): success result with serverVersion → .ok")
    func classifySuccess() throws {
        let json = """
        {
            "id": "req-1",
            "success": true,
            "result": {
                "pong": true,
                "serverVersion": "0.5.0",
                "serverProtocolVersion": 1,
                "minClientProtocolVersion": 1,
                "compatible": true
            }
        }
        """.data(using: .utf8)!
        let outcome = URLSessionPairingProbe.classify(envelope: json)
        #expect(outcome == .ok(serverVersion: "0.5.0"))
    }

    @Test("classify(): success result without serverVersion still ok")
    func classifySuccessNoVersion() throws {
        let json = """
        { "id": "x", "success": true, "result": { "pong": true } }
        """.data(using: .utf8)!
        let outcome = URLSessionPairingProbe.classify(envelope: json)
        #expect(outcome == .ok(serverVersion: nil))
    }

    @Test("classify(): error code CLIENT_VERSION_UNSUPPORTED → .incompatible")
    func classifyIncompatible() throws {
        let json = """
        {
            "id": "x",
            "success": false,
            "error": {
                "code": "CLIENT_VERSION_UNSUPPORTED",
                "message": "Upgrade required",
                "details": {
                    "serverVersion": "0.6.0",
                    "minClientProtocolVersion": 2
                }
            }
        }
        """.data(using: .utf8)!
        let outcome = URLSessionPairingProbe.classify(envelope: json)
        #expect(outcome == .incompatible(serverVersion: "0.6.0"))
    }

    @Test("classify(): error code CLIENT_VERSION_UNSUPPORTED without serverVersion still incompatible")
    func classifyIncompatibleNoVersion() throws {
        let json = """
        {
            "id": "x",
            "success": false,
            "error": {
                "code": "CLIENT_VERSION_UNSUPPORTED",
                "message": "Upgrade required"
            }
        }
        """.data(using: .utf8)!
        let outcome = URLSessionPairingProbe.classify(envelope: json)
        #expect(outcome == .incompatible(serverVersion: "unknown"))
    }

    @Test("classify(): any other error → .unreachable carrying message")
    func classifyOtherErrorBecomesUnreachable() throws {
        let json = """
        {
            "id": "x",
            "success": false,
            "error": { "code": "INTERNAL_ERROR", "message": "boom" }
        }
        """.data(using: .utf8)!
        let outcome = URLSessionPairingProbe.classify(envelope: json)
        #expect(outcome == .unreachable(reason: "boom"),
                "non-version errors should fall through to unreachable so the user sees the raw reason")
    }

    @Test("classify(): malformed envelope → .unreachable with parse hint")
    func classifyMalformed() throws {
        let json = "not json".data(using: .utf8)!
        let outcome = URLSessionPairingProbe.classify(envelope: json)
        if case .unreachable = outcome {
            // expected
        } else {
            Issue.record("expected .unreachable for malformed JSON, got \(outcome)")
        }
    }

    // MARK: - Outcome → PairingStepConnectError bridge

    @Test("toConnectError(): .unauthorized → PairingStepConnectError.unauthorized")
    func bridgeUnauthorized() {
        let err = PairingProbeOutcome.unauthorized.toConnectError()
        #expect(err == .unauthorized)
    }

    @Test("toConnectError(): .incompatible → PairingStepConnectError.incompatible")
    func bridgeIncompatible() {
        let err = PairingProbeOutcome.incompatible(serverVersion: "0.6.0").toConnectError()
        #expect(err == .incompatible(serverVersion: "0.6.0"))
    }

    @Test("toConnectError(): .unreachable → PairingStepConnectError.network")
    func bridgeUnreachable() {
        let err = PairingProbeOutcome.unreachable(reason: "DNS lookup failed").toConnectError()
        if case .network(let nsError) = err {
            #expect(nsError.domain == "PairingProbe")
            #expect(nsError.localizedDescription.contains("DNS lookup failed"))
        } else {
            Issue.record("expected .network, got \(err)")
        }
    }

    @Test("toConnectError(): .ok → nil (no error)")
    func bridgeOkIsNil() {
        let err = PairingProbeOutcome.ok(serverVersion: "0.5.0").toConnectError()
        #expect(err == nil)
    }
}
