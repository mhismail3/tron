import Foundation
import Testing
import UIKit
@testable import TronMobile

struct BrowserLiveViewingTests {
    private static func hello(capability: Bool = true) -> Data {
        Data("""
        {"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":\(capability ? "[\"browser-live-view.v1\"]" : "[]")}
        """.utf8)
    }
    private static func profile(_ id: String) -> GatewayProfile {
        GatewayProfile(id: id, label: "Fixture", host: "\(id).invalid", port: 9847, machineId: "machine", deviceId: "device")
    }

    @Test("an opened viewer keeps its original origin and credential across profile replacement, including cancelled cleanup")
    func originalLeaseOwnsCleanup() async throws {
        try await withTestWatchdog {
            let first = ScriptedGatewaySocket(), second = ScriptedGatewaySocket()
            let probe = BrowserLiveTransportProbe()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [first, second]).factory,
                browserLiveTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
            await first.enqueue(Self.hello())
            _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "first-secret")
            let lease = try await client.openBrowserLiveView(viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first")
            let update = try await lease.frame(after: 7)
            if case .waiting = update {} else { Issue.record("Expected a waiting response") }
            await second.enqueue(Self.hello())
            _ = try await client.connectForLifecycle(profile: Self.profile("second"), token: "second-secret")
            let closing = Task {
                try? await Task.sleep(for: .seconds(60))
                await lease.close()
            }
            closing.cancel()
            await closing.value
            await lease.close()
            await #expect(throws: CancellationError.self) { try await lease.frame(after: 1) }
            let requests = await probe.requests
            #expect(requests.map(\.request.httpMethod) == ["POST", "GET", "DELETE"])
            #expect(requests.allSatisfy { $0.request.url?.host == "first.invalid" })
            #expect(requests.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer first-secret" })
            #expect(requests[1].request.url?.path == "/v1/sessions/session-a/live-views/view-a/frame")
            #expect(requests[1].request.value(forHTTPHeaderField: "X-Tron-Live-After") == "7")
            #expect(requests[1].maximum == 2 * 1024 * 1024)
            #expect(requests[2].request.httpBody == nil)
            #expect(requests[2].request.value(forHTTPHeaderField: "X-Tron-Live-Generation") == "generation-a")
            #expect(requests[2].request.value(forHTTPHeaderField: "X-Tron-Live-Lease") == BrowserLiveTransportProbe.leaseID)
            #expect(requests[2].cancelled == false)
            await client.close()
        }
    }

    @Test("a late successful open is closed, not published, after profile replacement")
    func staleOpenIsClosed() async throws {
        try await withTestWatchdog {
            let first = ScriptedGatewaySocket(), second = ScriptedGatewaySocket()
            let probe = BrowserLiveTransportProbe(holdOpen: true)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [first, second]).factory,
                browserLiveTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
            await first.enqueue(Self.hello())
            _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "first-secret")
            let opening = Task { try await client.openBrowserLiveView(viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first") }
            await probe.waitForOpen()
            await second.enqueue(Self.hello())
            _ = try await client.connectForLifecycle(profile: Self.profile("second"), token: "second-secret")
            await probe.releaseOpen()
            await #expect(throws: CancellationError.self) { try await opening.value }
            let requests = await probe.requests
            #expect(requests.map(\.request.httpMethod) == ["POST", "DELETE"])
            #expect(requests.last?.request.url?.host == "first.invalid")
            await client.close()
        }
    }

    @Test("closing a lease fences a response already in flight")
    func closedLeaseRejectsLateFrame() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket(), probe = BrowserLiveTransportProbe(holdFrame: true)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                browserLiveTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
            await socket.enqueue(Self.hello())
            _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "secret")
            let lease = try await client.openBrowserLiveView(viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first")
            let reading = Task { try await lease.frame(after: 0) }
            await probe.waitForFrame()
            await lease.close()
            await probe.releaseFrame()
            await #expect(throws: CancellationError.self) { try await reading.value }
            #expect(await probe.requests.map(\.request.httpMethod) == ["POST", "GET", "DELETE"])
            await client.close()
        }
    }

    @Test("missing live-view capability performs no HTTP work")
    func capabilityAdmission() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket(), probe = BrowserLiveTransportProbe()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                browserLiveTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
            await socket.enqueue(Self.hello(capability: false))
            _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "secret")
            await #expect(throws: GatewayClient.BrowserLiveError.self) {
                try await client.openBrowserLiveView(viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first")
            }
            #expect(await probe.requests.isEmpty)
            await client.close()
        }
    }

    @Test("retired synchronous preparation drains before a replacement can decode")
    func retiredPreparationDoesNotOverlap() async throws {
        try await withTestWatchdog {
            let preparation = BrowserLiveImagePreparation()
            let (started, arrival) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let first = Task {
                defer { arrival.finish() }
                return try await preparation.prepare {
                    arrival.yield(())
                    guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
                    return UIImage()
                }
            }
            var observed = false
            for await _ in started { observed = true; break }
            #expect(observed)
            first.cancel()
            // Model a non-cancellable native call. Cancellation must not release
            // its slot early or queue replacement ImageIO work behind it.
            for _ in 0..<3 {
                let replacement = try await preparation.prepare { UIImage() }
                #expect(replacement == nil)
            }
            release.signal()
            await #expect(throws: CancellationError.self) { try await first.value }
            let next = try await preparation.prepare { UIImage() }
            #expect(next != nil)
        }
    }

    @MainActor @Test("actual JPEG decoding checks encoded dimensions, bytes, MIME, and cancellation")
    func frameAdmissionAndDecode() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        func response(width: String = "1", height: String = "1", mime: String = "image/jpeg") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "http://fixture.invalid/frame")!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": mime, "X-Tron-Live-Width": width, "X-Tron-Live-Height": height, "X-Tron-Live-Sequence": "1"])!
        }
        let frame = try GatewayClient.BrowserLiveFrame(data: jpeg, response: response())
        let image = try await frame.decode()
        #expect(image?.cgImage?.width == 1 && image?.cgImage?.height == 1)
        let mismatch = try GatewayClient.BrowserLiveFrame(data: jpeg, response: response(width: "2"))
        await #expect(throws: GatewayClient.BrowserLiveError.self) { try await mismatch.decode() }
        let corrupt = try GatewayClient.BrowserLiveFrame(data: Data("not jpeg".utf8), response: response())
        await #expect(throws: GatewayClient.BrowserLiveError.self) { try await corrupt.decode() }
        for invalid in [response(width: "2561"), response(width: "2500", height: "2500"), response(mime: "image/png")] {
            #expect(throws: GatewayClient.BrowserLiveError.self) { try GatewayClient.BrowserLiveFrame(data: jpeg, response: invalid) }
        }
        #expect(throws: GatewayClient.BrowserLiveError.self) {
            try GatewayClient.BrowserLiveFrame(data: Data(count: GatewayClient.BrowserLiveFrame.maximumEncodedBytes + 1), response: response())
        }
        let decoding = Task {
            try? await Task.sleep(for: .seconds(60))
            return try await frame.decode()
        }
        decoding.cancel()
        await #expect(throws: CancellationError.self) { try await decoding.value }
    }
}

private actor BrowserLiveTransportProbe {
    static let leaseID = "00000000-0000-4000-8000-000000000001"
    struct Recorded: Sendable { let request: URLRequest; let maximum: Int; let cancelled: Bool }
    private(set) var requests: [Recorded] = []
    private let holdOpen: Bool
    private let holdFrame: Bool
    private var framing = false
    private var frameWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldFrame: CheckedContinuation<Void, Never>?
    private var opening = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldOpen: CheckedContinuation<Void, Never>?
    init(holdOpen: Bool = false, holdFrame: Bool = false) {
        self.holdOpen = holdOpen; self.holdFrame = holdFrame
    }
    func waitForFrame() async {
        if framing { return }
        await withCheckedContinuation { frameWaiters.append($0) }
    }
    func releaseFrame() { heldFrame?.resume(); heldFrame = nil }
    func waitForOpen() async {
        if opening { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }
    func releaseOpen() { heldOpen?.resume(); heldOpen = nil }
    func respond(_ request: URLRequest, _ maximum: Int) async -> (Data, HTTPURLResponse) {
        requests.append(Recorded(request: request, maximum: maximum, cancelled: Task.isCancelled))
        if request.httpMethod == "POST" {
            opening = true
            openWaiters.forEach { $0.resume() }; openWaiters.removeAll()
            if holdOpen { await withCheckedContinuation { heldOpen = $0 } }
            let data = Data("""
            {"leaseId":"\(Self.leaseID)","descriptor":{"schema":"tron.browser-live-view.v1","viewId":"view-a","generation":"generation-a","title":"Browser","fallbackText":"Unavailable"}}
            """.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!)
        }
        if request.httpMethod == "GET" {
            framing = true
            frameWaiters.forEach { $0.resume() }; frameWaiters.removeAll()
            if holdFrame { await withCheckedContinuation { heldFrame = $0 } }
        }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: ["X-Tron-Live-State":"waiting"])!)
    }
}
