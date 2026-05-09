import Foundation
import Testing
@testable import TronMobile

/// `PairingProbe` is the one-shot reachability check the onboarding
/// PairingStep runs before committing the new bearer token + paired server.
///
/// The production probe is `URLSessionPairingProbe`, which opens a single
/// WebSocket upgrade to `ws://<host>:<port>/engine` carrying
/// `Authorization: Bearer <token>`, sends a `system::ping` JSON-engine protocol frame,
/// and classifies the outcome. Tests focus on the **pure** parts of that
/// pipeline:
///
///   1. `urlString(host:port:)` URL formatting (host with `:` for IPv6,
///      hostname vs IP, default port).
///   2. `pingRequestData(protocolVersion:clientVersion:)` JSON encoding
///      (matches what `system::ping` consumes in
///      `packages/agent/src/domains/system/mod.rs`).
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
        #expect(url == "ws://100.64.0.7:9847/engine")
    }

    @Test("urlString(): hostname (MagicDNS) works the same as an IP")
    func urlStringHostname() {
        let url = URLSessionPairingProbe.urlString(host: "mac-name.tail-scale.ts.net", port: 9847)
        #expect(url == "ws://mac-name.tail-scale.ts.net:9847/engine")
    }

    @Test("urlString(): IPv6 literal gets bracketed")
    func urlStringIPv6() {
        let url = URLSessionPairingProbe.urlString(host: "fd7a:115c:a1e0::1", port: 9847)
        #expect(url == "ws://[fd7a:115c:a1e0::1]:9847/engine",
                "IPv6 literals must be wrapped in brackets per RFC 3986")
    }

    @Test("urlString(): non-default port is preserved verbatim")
    func urlStringCustomPort() {
        let url = URLSessionPairingProbe.urlString(host: "h", port: 9000)
        #expect(url == "ws://h:9000/engine")
    }

    // MARK: - Ping payload

    @Test("pingRequestData(): produces an engine invoke frame with protocolVersion + clientVersion")
    func pingPayloadShape() throws {
        let data = URLSessionPairingProbe.pingRequestData(
            protocolVersion: 1,
            clientVersion: "1.2.3",
            requestId: "req-1"
        )
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["id"] as? String == "req-1")
        #expect(parsed?["type"] as? String == "invoke")
        #expect(parsed?["functionId"] as? String == "system::ping")
        let payload = parsed?["payload"] as? [String: Any]
        #expect(payload?["protocolVersion"] as? Int == 1)
        #expect(payload?["clientVersion"] as? String == "1.2.3")
    }

    // MARK: - Classification

    @Test("classify(): success result with serverVersion → .ok")
    func classifySuccess() throws {
        let json = """
        {
            "id": "req-1",
            "ok": true,
            "result": {
                "child": {
                    "value": {
                        "pong": true,
                        "serverVersion": "0.5.0",
                        "serverProtocolVersion": 1,
                        "minClientProtocolVersion": 1,
                        "compatible": true
                    }
                }
            }
        }
        """.data(using: .utf8)!
        let outcome = URLSessionPairingProbe.classify(envelope: json)
        #expect(outcome == .ok(serverVersion: "0.5.0"))
    }

    @Test("classify(): success result without serverVersion still ok")
    func classifySuccessNoVersion() throws {
        let json = """
        { "id": "x", "ok": true, "result": { "child": { "value": { "pong": true } } } }
        """.data(using: .utf8)!
        let outcome = URLSessionPairingProbe.classify(envelope: json)
        #expect(outcome == .ok(serverVersion: nil))
    }

    @Test("classify(): error code CLIENT_VERSION_UNSUPPORTED → .incompatible")
    func classifyIncompatible() throws {
        let json = """
        {
            "id": "x",
            "ok": false,
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
            "ok": false,
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
            "ok": false,
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

    @Test("classifyFrame(): ignores connection.established before matching ping response")
    func classifyFrameIgnoresConnectionEstablishedEvent() {
        let event = """
        {
            "type": "connection.established",
            "timestamp": "2026-04-26T00:00:00Z",
            "data": { "clientId": "c" }
        }
        """.data(using: .utf8)!

        let frame = URLSessionPairingProbe.classifyFrame(
            envelope: event,
            expectedRequestId: "pairing-ping"
        )

        #expect(frame == .ignore)
    }

    @Test("classifyFrame(): ignores non-matching engine protocol response ids")
    func classifyFrameIgnoresOtherResponses() {
        let response = """
        { "id": "other", "ok": true, "result": { "child": { "value": { "pong": true } } } }
        """.data(using: .utf8)!

        let frame = URLSessionPairingProbe.classifyFrame(
            envelope: response,
            expectedRequestId: "pairing-ping"
        )

        #expect(frame == .ignore)
    }

    @Test("classifyFrame(): classifies matching ping response")
    func classifyFrameMatchesPingResponse() {
        let response = """
        {
            "id": "pairing-ping",
            "ok": true,
            "result": { "child": { "value": { "pong": true, "serverVersion": "0.5.0" } } }
        }
        """.data(using: .utf8)!

        let frame = URLSessionPairingProbe.classifyFrame(
            envelope: response,
            expectedRequestId: "pairing-ping"
        )

        #expect(frame == .outcome(.ok(serverVersion: "0.5.0")))
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

    // MARK: - Upgrade auth response sniffing

    @Test("ProbeSessionDelegate records HTTP 401 upgrade responses")
    func delegateRecordsUnauthorizedResponse() throws {
        let delegate = ProbeSessionDelegate()
        let url = try #require(URL(string: "ws://127.0.0.1:9847/engine"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        ))

        #expect(delegate.observedUnauthorized == false)
        delegate.record(response: response)
        #expect(delegate.observedUnauthorized == true)
    }

    @Test("ProbeSessionDelegate ignores non-401 responses")
    func delegateIgnoresNonUnauthorizedResponse() throws {
        let delegate = ProbeSessionDelegate()
        let url = try #require(URL(string: "ws://127.0.0.1:9847/engine"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 101,
            httpVersion: nil,
            headerFields: nil
        ))

        delegate.record(response: response)
        #expect(delegate.observedUnauthorized == false)
    }

    @Test("ProbeSessionDelegate wait catches a 401 that arrives after the transport error")
    func delegateWaitsBrieflyForUnauthorizedResponse() async throws {
        let delegate = ProbeSessionDelegate()
        let url = try #require(URL(string: "ws://127.0.0.1:9847/engine"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        ))

        Task {
            try? await Task.sleep(for: .milliseconds(20))
            delegate.record(response: response)
        }

        let observed = await delegate.waitForUnauthorized(timeout: .milliseconds(250))
        #expect(observed)
    }
}
