import Foundation
import Testing
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
