import Foundation
import Testing
@testable import TronMobileCore
@testable import TronMobile

@Suite("Gateway pairing HTTP transport")
struct GatewayPairingTransportTests {
    private let invitation = PairingInvitation(
        host: "gateway.test",
        port: 9_847,
        code: "12345678",
        machineId: nil,
        label: "Office Mac"
    )

    @Test("POST /v1/pair has the exact endpoint, timeout, headers, and JSON fields")
    func exactRequest() async throws {
        let recorder = PairingHTTPRecorder(response: Self.response(
            status: 200,
            body: #"{"deviceId":"device-1","token":"secret-token","machineId":"machine-1","machineGroupID":"physical-1","machineName":"Runtime Mac","gatewayChannel":"stable"}"#
        ))
        let pairer = GatewayPairer(transport: recorder.transport, uuidSource: { "connection-1" })

        let (profile, token) = try await pairer.pair(invitation, deviceName: "Test iPhone")
        let requests = await recorder.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url?.absoluteString == "http://gateway.test:9847/v1/pair")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 15)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"code":"12345678","deviceName":"Test iPhone"}"#)
        #expect(try JSONDecoder.gateway.decode(JSONValue.self, from: body) == .object([
            "code": .string("12345678"),
            "deviceName": .string("Test iPhone"),
        ]))
        #expect(profile == GatewayProfile(
            id: "connection-1",
            label: "Office Mac",
            host: "gateway.test",
            port: 9_847,
            machineId: "machine-1",
            machineGroupID: "physical-1",
            deviceId: "device-1"
        ))
        #expect(token == "secret-token")
    }

    @Test("a missing invitation label falls back to the paired machine name")
    func machineNameFallback() async throws {
        let recorder = PairingHTTPRecorder(response: Self.response(
            status: 200,
            body: #"{"deviceId":"device-1","token":"secret-token","machineId":"machine-1","machineGroupID":"physical-1","machineName":"Runtime Mac","gatewayChannel":"stable"}"#
        ))
        let pairer = GatewayPairer(transport: recorder.transport, uuidSource: { "connection-2" })
        let unlabeledInvitation = PairingInvitation(
            host: invitation.host,
            port: invitation.port,
            code: invitation.code,
            machineId: invitation.machineId,
            label: nil
        )

        let (profile, _) = try await pairer.pair(unlabeledInvitation, deviceName: "Test iPhone")

        #expect(profile.label == "Runtime Mac")
    }

    @Test("Debug pairing admits dev and both endpoints reject missing or mismatched channel identity")
    func channelIdentityAdmission() async throws {
        let debugInvitation = PairingInvitation(
            host: invitation.host,
            port: 9_848,
            code: invitation.code,
            machineId: nil,
            label: "Debug Mac"
        )
        let debug = GatewayPairer(transport: PairingHTTPRecorder(response: Self.response(
            status: 200,
            body: #"{"deviceId":"device-dev","token":"debug-token","machineId":"machine-dev","machineName":"Debug Mac","gatewayChannel":"dev"}"#
        )).transport)
        let (debugProfile, _) = try await debug.pair(debugInvitation, deviceName: "Test iPhone")
        #expect(debugProfile.port == 9_848)
        #expect(debugProfile.gatewayChannel == "dev")

        for (target, body) in [
            (invitation, #"{"deviceId":"device-1","token":"token","machineId":"machine","machineName":"Mac","gatewayChannel":"dev"}"#),
            (debugInvitation, #"{"deviceId":"device-1","token":"token","machineId":"machine","machineName":"Mac","gatewayChannel":"stable"}"#),
            (invitation, #"{"deviceId":"device-1","token":"token","machineId":"machine","machineName":"Mac"}"#),
            (invitation, #"{"deviceId":"device-1","token":"token","machineId":"machine","machineName":"Mac","gatewayChannel":"preview"}"#),
        ] {
            let pairer = GatewayPairer(transport: PairingHTTPRecorder(
                response: Self.response(status: 200, body: body)
            ).transport)
            do {
                _ = try await pairer.pair(target, deviceName: "Test iPhone")
                Issue.record("pairing unexpectedly admitted \(body)")
            } catch {
                // Missing, invalid, and endpoint-mismatched channels fail closed.
            }
        }
    }

    @Test("a pairing response gives the profile the LAN endpoints and pin")
    func pairingAdoptsLanAdvertisement() async throws {
        let pin = Data(repeating: 9, count: 32).base64EncodedString()
        let recorder = PairingHTTPRecorder(response: Self.response(
            status: 200,
            body: #"{"deviceId":"device-1","token":"secret-token","machineId":"machine-1","machineName":"Runtime Mac","gatewayChannel":"stable","lanEndpoints":[{"host":"192.168.1.24","port":9847}],"lanPin":"\#(pin)"}"#
        ))
        let pairer = GatewayPairer(transport: recorder.transport, uuidSource: { "connection-lan" })

        let (profile, _) = try await pairer.pair(invitation, deviceName: "Test iPhone")

        // Pairing is the first authenticated channel, so it is where the phone
        // learns the LAN leg it may race (E-3c); every later hello replaces it.
        #expect(profile.lanEndpoints == [GatewayLanEndpoint(host: "192.168.1.24", port: 9_847)])
        #expect(profile.lanPin == pin)
    }

    @Test("a paired LAN endpoint composes the TLS socket and HTTP base the race dials")
    func lanEndpointURLs() throws {
        let ipv4 = try #require(GatewayLanEndpoint(host: "192.168.1.24", port: 9_847))
        #expect(ipv4.socketURL?.absoluteString == "wss://192.168.1.24:9847/v1/socket")
        #expect(ipv4.httpURL(path: "/health")?.absoluteString == "https://192.168.1.24:9847/health")
        #expect(ipv4.httpURL(path: "/v1/sessions", queryItems: [URLQueryItem(name: "limit", value: "50")])
            == URL(string: "https://192.168.1.24:9847/v1/sessions?limit=50"))

        // A Mac whose only private address is an IPv6 ULA: the lane is TLS, and
        // a bare literal is not a URL authority.
        let ula = try #require(GatewayLanEndpoint(host: "fd12:3456:789A::1", port: 9_847))
        #expect(ula.host == "fd12:3456:789a::1")
        #expect(ula.socketURL?.absoluteString == "wss://[fd12:3456:789a::1]:9847/v1/socket")
        #expect(ula.httpURL()?.absoluteString == "https://[fd12:3456:789a::1]:9847")

        // An endpoint a socket cannot be composed for is not stored at all.
        #expect(GatewayLanEndpoint(host: "[fd12::1]", port: 9_847) == nil)
        #expect(GatewayLanEndpoint(host: "192.168.1.24", port: 0) == nil)
        #expect(GatewayLanEndpoint.sanitized([ipv4, ula]).count == 2)
    }

    @Test("a non-200 structured Gateway error is preserved exactly")
    func structuredFailure() async throws {
        let recorder = PairingHTTPRecorder(response: Self.response(
            status: 403,
            body: #"{"error":{"code":"invalid_pairing_code","message":"Code expired.","retryable":true,"details":{"remaining":0}}}"#
        ))
        let pairer = GatewayPairer(transport: recorder.transport)

        do {
            _ = try await pairer.pair(invitation, deviceName: "Test iPhone")
            Issue.record("pairing unexpectedly succeeded")
        } catch let failure as GatewayFailure {
            #expect(failure.code == "invalid_pairing_code")
            #expect(failure.message == "Code expired.")
            #expect(failure.retryable)
            #expect(failure.details == .object(["remaining": .number(0)]))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("an undecodable non-200 body maps to the stable generic pairing error")
    func genericFailure() async throws {
        let recorder = PairingHTTPRecorder(response: Self.response(status: 500, body: "not-json"))
        let pairer = GatewayPairer(transport: recorder.transport)

        do {
            _ = try await pairer.pair(invitation, deviceName: "Test iPhone")
            Issue.record("pairing unexpectedly succeeded")
        } catch let failure as GatewayFailure {
            #expect(failure == GatewayFailure(
                code: "pairing_failed",
                message: "The Mac rejected this pairing code.",
                retryable: false,
                details: nil
            ))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("transport errors propagate without pairing remapping")
    func transportFailure() async throws {
        let pairer = GatewayPairer(transport: HTTPDataTransport { _ in
            throw URLError(.cannotConnectToHost)
        })

        do {
            _ = try await pairer.pair(invitation, deviceName: "Test iPhone")
            Issue.record("pairing unexpectedly succeeded")
        } catch let error as URLError {
            #expect(error.code == .cannotConnectToHost)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("pairing responses are rejected above the transport budget")
    func oversizedResponse() async {
        let oversized = String(repeating: "x", count: GatewayPairingPolicy.maximumResponseBytes + 1)
        let pairer = GatewayPairer(transport: PairingHTTPRecorder(
            response: Self.response(status: 200, body: oversized)
        ).transport)

        do {
            _ = try await pairer.pair(invitation, deviceName: "Test iPhone")
            Issue.record("oversized pairing response unexpectedly succeeded")
        } catch let error as URLError {
            #expect(error.code == .dataLengthExceedsMaximum)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a malformed 200 response remains a decoding failure")
    func malformedSuccess() async throws {
        let recorder = PairingHTTPRecorder(response: Self.response(status: 200, body: #"{"token":"only"}"#))
        let pairer = GatewayPairer(transport: recorder.transport)

        do {
            _ = try await pairer.pair(invitation, deviceName: "Test iPhone")
            Issue.record("pairing unexpectedly succeeded")
        } catch is DecodingError {
            // Expected: a 200 response must satisfy the complete success schema.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private static func response(status: Int, body: String) -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://gateway.test:9847/v1/pair")!
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor PairingHTTPRecorder {
    private(set) var requests: [URLRequest] = []
    private let response: (Data, HTTPURLResponse)

    init(response: (Data, HTTPURLResponse)) {
        self.response = response
    }

    nonisolated var transport: HTTPDataTransport {
        HTTPDataTransport { request in
            await self.record(request)
        }
    }

    private func record(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return response
    }
}
