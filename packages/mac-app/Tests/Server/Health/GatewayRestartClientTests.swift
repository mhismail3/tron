import Foundation
import Testing
@testable import TronMac

@Suite("GatewayRestartClient protocol policy")
struct GatewayRestartClientTests {
    @Test("request policy resolves the socket path and bearer header")
    func requestPolicy() throws {
        let request = try GatewayRestartClient.makeRequest(
            host: "127.0.0.1",
            port: 9847,
            token: "local-token",
            timeout: 2
        )
        #expect(request.url?.absoluteString == "ws://127.0.0.1:9847/v1/socket")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")
        let ipv6 = try GatewayRestartClient.makeRequest(
            host: "fd7a:115c:a1e0::1",
            port: 9848,
            token: "local-token"
        )
        #expect(ipv6.url?.absoluteString == "ws://[fd7a:115c:a1e0::1]:9848/v1/socket")
        #expect(throws: GatewayRestartClient.Failure.missingCredential) {
            try GatewayRestartClient.makeRequest(host: "127.0.0.1", port: 9847, token: nil)
        }
    }

    @Test("restart command IDs are bounded and printable")
    func commandIDPolicy() {
        #expect(GatewayRestartClient.validCommandID("mac-restart-12345678"))
        #expect(!GatewayRestartClient.validCommandID("short"))
        #expect(!GatewayRestartClient.validCommandID(String(repeating: "x", count: 161)))
        #expect(!GatewayRestartClient.validCommandID("restart\ncommand"))
    }

    @Test("matching restart response is decoded")
    func responseDecoding() {
        let body = #"{"type":"response","id":"command-123","ok":true,"result":{"restarting":true,"scheduled":false,"activeSessionIds":[]}}"#
        #expect(
            GatewayRestartClient.decodeFrame(data: Data(body.utf8), expectedID: "command-123")
                == .result(.init(restarting: true, scheduled: false, activeSessionIds: []))
        )
    }

    @Test("gateway errors are preserved and unrelated frames are ignored")
    func errorsAndUnrelatedFrames() {
        let error = #"{"type":"response","id":"command-123","ok":false,"error":{"code":"busy","message":"Close active terminal sessions before restarting the Gateway","retryable":true}}"#
        let event = #"{"type":"event","topic":"system.stopping"}"#
        #expect(
            GatewayRestartClient.decodeFrame(data: Data(error.utf8), expectedID: "command-123")
                == .error(.gateway(code: "busy", message: "Close active terminal sessions before restarting the Gateway", retryable: true))
        )
        #expect(GatewayRestartClient.decodeFrame(data: Data(event.utf8), expectedID: "command-123") == .ignore)
    }

    @Test("cancellation propagates from the shared socket operation")
    func cancellationPropagates() async {
        let task = Task {
            try await GatewayRestartClient.restart(
                host: "127.0.0.1", port: 1, token: "local-token", timeout: 10
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not become generic transport failure.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("success frames with invalid result shape are rejected")
    func invalidResultIsMalformed() {
        let body = #"{"type":"response","id":"command-123","ok":true,"result":{"restarting":"yes","scheduled":false,"activeSessionIds":[]}}"#
        #expect(GatewayRestartClient.decodeFrame(data: Data(body.utf8), expectedID: "command-123") == .malformed)
    }
}
