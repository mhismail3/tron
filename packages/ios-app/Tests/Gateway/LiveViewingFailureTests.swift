import Foundation
import Testing
import UIKit
@testable import TronMobile

@Suite("Live preview failures and bounded transport recovery", .serialized)
struct LiveViewingFailureTests {
    @Test func failureTextUsesOnlyFiniteClassifications() {
        let failure = GatewayClient.LiveError.response(Data("""
        {"error":{"code":"not_found","retryable":true,"message":"private /secret/path","details":{"liveViewFailure":"source_unavailable","secret":"do not render"}}}
        """.utf8), status: 404)
        #expect(failure == .sourceUnavailable)
        #expect(!failure.isTransient)
        #expect(!failure.message.contains("secret"))
        let unknown = GatewayClient.LiveError.response(Data("""
        {"error":{"code":"internal","message":"private /secret/path","details":{"liveViewFailure":"arbitrary user text"}}}
        """.utf8), status: 500)
        #expect(unknown == .captureUnavailable)
        #expect(!unknown.message.contains("secret"))
        #expect(GatewayClient.LiveError.response(Data(repeating: 0, count: 8_193), status: 503) == .invalidResponse)
    }

    @Test(arguments: [false, true]) @MainActor func transientReadReturnsActualPixelsOnTheSameLease(transportFailure: Bool) async throws {
        try await withTestWatchdog {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3), format: format).image { context in
                UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
            }
            let jpeg = try #require(image.jpegData(compressionQuality: 1))
            let probe = LiveFailureTransportProbe(failures: 1, terminal: false, jpeg: jpeg, transportFailure: transportFailure)
            let lease = try Self.lease(probe)
            let result = try await lease.frame(after: 17)
            guard case let .frame(frame) = result else { Issue.record("Expected frame after transient error"); await lease.close(); return }
            // Inspect recovered bytes independently; the mounted viewer suite
            // owns the shared production decode-slot/painting assertions.
            let decoded = try #require(UIImage(data: frame.data))
            #expect(decoded.size == CGSize(width: 2, height: 3))
            await lease.close()
            let requests = await probe.requests
            #expect(requests.map(\.httpMethod) == ["GET", "GET", "DELETE"])
            #expect(requests.prefix(2).allSatisfy { $0.value(forHTTPHeaderField: "X-Tron-Live-After") == "17" && $0.timeoutInterval == 3 })
            #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Tron-Live-Lease") == Self.leaseID })
            #expect(requests.allSatisfy { $0.url?.host == "first.invalid" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" })
        }
    }

    @Test func terminalSourceFailureDoesNotRetryOrReopen() async throws {
        try await withTestWatchdog {
            let probe = LiveFailureTransportProbe(failures: 10, terminal: true)
            let lease = try Self.lease(probe)
            await #expect(throws: GatewayClient.LiveError.sourceUnavailable) { try await lease.frame(after: 0) }
            await lease.close()
            #expect(await probe.requests.map(\.httpMethod) == ["GET", "DELETE"])
        }
    }

    @Test func transientRetryBudgetIsFinite() async throws {
        try await withTestWatchdog {
            let probe = LiveFailureTransportProbe(failures: 10, terminal: false)
            let lease = try Self.lease(probe)
            await #expect(throws: GatewayClient.LiveError.temporarilyUnavailable) { try await lease.frame(after: 0) }
            await lease.close()
            #expect(await probe.requests.map(\.httpMethod) == ["GET", "GET", "GET", "DELETE"])
        }
    }

    @Test func cancellationPreventsRetryAndStillJoinsCleanup() async throws {
        try await withTestWatchdog {
            let probe = LiveFailureTransportProbe(failures: 10, terminal: false, holdRead: true)
            let lease = try Self.lease(probe)
            let reading = Task { try await lease.frame(after: 0) }
            await probe.waitForRead()
            reading.cancel(); await probe.releaseRead()
            await #expect(throws: CancellationError.self) { try await reading.value }
            await lease.close(); await lease.close()
            #expect(await probe.requests.map(\.httpMethod) == ["GET", "DELETE"])
        }
    }

    private static let leaseID = "11111111-1111-4111-8111-111111111111"
    private static func lease(_ probe: LiveFailureTransportProbe) throws -> GatewayClient.LiveLease {
        var request = URLRequest(url: URL(string: "https://first.invalid/v1/sessions/session/live-views/view")!)
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        return try GatewayClient.LiveLease(wire: .init(leaseId: leaseID,
            descriptor: .init(schema: "tron.native-live-view.v1", viewId: "view", generation: "generation", title: "Fixture", fallbackText: "Not an error message")),
            request: request, transport: BoundedHTTPDataTransport { request, _ in try await probe.respond(request) })
    }
}

private actor LiveFailureTransportProbe {
    var requests: [URLRequest] = []
    private var failures: Int
    private let terminal: Bool
    private let jpeg: Data
    private let holdRead: Bool
    private let transportFailure: Bool
    private var released = false
    private var readGate: CheckedContinuation<Void, Never>?
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    init(failures: Int, terminal: Bool, jpeg: Data = Data(), holdRead: Bool = false, transportFailure: Bool = false) {
        self.failures = failures; self.terminal = terminal; self.jpeg = jpeg; self.holdRead = holdRead; self.transportFailure = transportFailure
    }
    func releaseRead() { released = true; readGate?.resume(); readGate = nil }
    func waitForRead() async {
        if requests.contains(where: { $0.httpMethod == "GET" }) { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        var status = 204, data = Data(), headers: [String: String] = [:]
        if request.httpMethod == "GET" {
            for waiter in readWaiters { waiter.resume() }; readWaiters.removeAll()
            if holdRead && !released { await withCheckedContinuation { readGate = $0 } }
            if failures > 0 {
                failures -= 1
                if transportFailure { throw URLError(.networkConnectionLost) }
                status = terminal ? 404 : 503
                data = Data((terminal
                    ? "{\"error\":{\"code\":\"not_found\",\"retryable\":false,\"details\":{\"liveViewFailure\":\"source_unavailable\"}}}"
                    : "{\"error\":{\"code\":\"busy\",\"retryable\":true}}").utf8)
                headers["Content-Type"] = "application/json"
            } else {
                status = 200; data = jpeg
                headers = ["Content-Type": "image/jpeg", "X-Tron-Live-Width": "2", "X-Tron-Live-Height": "3", "X-Tron-Live-Sequence": "18"]
            }
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
