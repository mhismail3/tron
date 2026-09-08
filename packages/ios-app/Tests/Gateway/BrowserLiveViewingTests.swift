import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite(.serialized)
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

    @MainActor @Test("independent frame decodes contend on the production app-wide preparation owner")
    func frameDecodesSharePreparationOwner() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let response = HTTPURLResponse(url: URL(string: "http://fixture.invalid/frame")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg", "X-Tron-Live-Width": "1", "X-Tron-Live-Height": "1", "X-Tron-Live-Sequence": "1"])!
        let firstFrame = try GatewayClient.BrowserLiveFrame(data: jpeg, response: response)
        let secondFrame = try GatewayClient.BrowserLiveFrame(data: jpeg, response: response)
        try await withTestWatchdog {
            let (started, arrival) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let release = DispatchSemaphore(value: 0)
            let occupied = Task {
                defer { arrival.finish() }
                return try await BrowserLiveImagePreparation.shared.prepare {
                    arrival.yield(())
                    guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
                    return UIImage()
                }
            }
            do {
                var observed = false
                for await _ in started { observed = true; break }
                try #require(observed)
                async let first = firstFrame.decode()
                async let second = secondFrame.decode()
                let images = try await (first, second)
                #expect(images.0 == nil && images.1 == nil)
            } catch {
                release.signal()
                _ = try? await occupied.value
                throw error
            }
            release.signal()
            #expect(try await occupied.value != nil)
            #expect(try await firstFrame.decode() != nil)
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
    private var outstandingLeases: Set<String> = []
    private var nextLease = 0
    private var activeRequests = 0
    private var finished = false
    var drained: Bool { activeRequests == 0 && outstandingLeases.isEmpty }
    private let holdOpen: Bool
    private let holdFrame: Bool
    private let echoDescriptor: Bool
    private var framing = false
    private var frameWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldFrames: [CheckedContinuation<Void, Never>] = []
    private var opening = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldOpens: [CheckedContinuation<Void, Never>] = []
    init(holdOpen: Bool = false, holdFrame: Bool = false, echoDescriptor: Bool = false) {
        self.holdOpen = holdOpen; self.holdFrame = holdFrame; self.echoDescriptor = echoDescriptor
    }
    func waitForFrame() async {
        if framing { return }
        await withCheckedContinuation { frameWaiters.append($0) }
    }
    func releaseFrame() { heldFrames.forEach { $0.resume() }; heldFrames.removeAll() }
    func waitForOpen() async {
        if opening { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }
    func releaseOpen() { heldOpens.forEach { $0.resume() }; heldOpens.removeAll() }
    func finish() {
        finished = true
        releaseOpen(); releaseFrame()
        openWaiters.forEach { $0.resume() }; openWaiters.removeAll()
        frameWaiters.forEach { $0.resume() }; frameWaiters.removeAll()
    }
    func respond(_ request: URLRequest, _ maximum: Int) async -> (Data, HTTPURLResponse) {
        activeRequests += 1
        defer { activeRequests -= 1 }
        requests.append(Recorded(request: request, maximum: maximum, cancelled: Task.isCancelled))
        if request.httpMethod == "POST" {
            nextLease += 1
            let leaseID = String(format: "00000000-0000-4000-8000-%012d", nextLease)
            outstandingLeases.insert(leaseID)
            opening = true
            openWaiters.forEach { $0.resume() }; openWaiters.removeAll()
            if holdOpen && !finished { await withCheckedContinuation { heldOpens.append($0) } }
            let descriptorViewID: String
            let descriptorGeneration: String
            if echoDescriptor {
                descriptorViewID = request.url?.pathComponents.last ?? ""
                descriptorGeneration = (try? JSONDecoder.gateway.decode(
                    OpenBody.self, from: request.httpBody ?? Data()
                ).generation) ?? ""
            } else {
                descriptorViewID = "view-a"
                descriptorGeneration = "generation-a"
            }
            let data = Data("""
            {"leaseId":"\(leaseID)","descriptor":{"schema":"tron.browser-live-view.v1","viewId":"\(descriptorViewID)","generation":"\(descriptorGeneration)","title":"Browser","fallbackText":"Unavailable"}}
            """.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!)
        }
        if request.httpMethod == "GET" {
            framing = true
            frameWaiters.forEach { $0.resume() }; frameWaiters.removeAll()
            if holdFrame && !finished { await withCheckedContinuation { heldFrames.append($0) } }
        }
        if request.httpMethod == "DELETE", let leaseID = request.value(forHTTPHeaderField: "X-Tron-Live-Lease") {
            outstandingLeases.remove(leaseID)
        }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: ["X-Tron-Live-State":"waiting"])!)
    }

    private struct OpenBody: Decodable {
        let generation: String
    }
}

@MainActor
@Suite("Mounted browser live display", .serialized)
struct BrowserLiveMountedViewingTests {
    @Test("an inactive mounted host stops polling and closes its lease")
    func inactiveHostStopsPolling() async throws {
        let probe = BrowserLiveTransportProbe(holdFrame: true)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("mounted-inactive")) { _, state, _, _ in
            try await Self.waitForRequests(2, probe: probe)
            state.sceneActive = false
            await probe.releaseFrame()
            try await Self.waitForRequests(3, probe: probe)
            #expect(await probe.requests.map(\.request.httpMethod) == ["POST", "GET", "DELETE"])
            let stoppedCount = await probe.requests.count
            try await Task.sleep(for: .milliseconds(350))
            #expect(await probe.requests.count == stoppedCount)
        }
    }

    @Test("an active DisplaySheet polls, while a covered retained host performs no work and joins cleanup")
    func coveredRetainedHostStopsPolling() async throws {
        let probe = BrowserLiveTransportProbe(holdFrame: true)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("mounted")) { _, state, coordinator, host in
            try await Self.waitForRequests(2, probe: probe)
            #expect(await probe.requests.map(\.request.httpMethod) == ["POST", "GET"])
            #expect(coordinator.mountedSurfaceCount == 1)

            state.covered = true
            try await Self.waitForSurfaceCount(2, coordinator: coordinator)
            await probe.releaseFrame()
            try await Self.waitForRequests(3, probe: probe)
            #expect(await probe.requests.map(\.request.httpMethod) == ["POST", "GET", "DELETE"])
            let coveredCount = await probe.requests.count
            try await Task.sleep(for: .milliseconds(450))
            #expect(await probe.requests.count == coveredCount)
            let surface = try #require(state.surface)
            #expect(coordinator.activity(for: surface) == .presentingDescendant)

            // Retire the actual hosting controller, not merely its visibility.
            host.dismissAndTearDown()
            try await Self.waitForSurfaceCount(0, coordinator: coordinator)
            #expect(await probe.requests.count == coveredCount)
        }
    }

    @Test("a dismissed host fences an in-flight open and the late response closes its original lease")
    func dismissedHostFencesOpen() async throws {
        let probe = BrowserLiveTransportProbe(holdOpen: true)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("mounted-open")) { _, state, coordinator, _ in
            try await Self.waitForRequests(1, probe: probe)
            state.mounted = false
            await probe.releaseOpen()
            try await Self.waitForRequests(2, probe: probe)
            #expect(await probe.requests.map(\.request.httpMethod) == ["POST", "DELETE"])
            #expect(await probe.requests.allSatisfy { $0.request.url?.host == "mounted-open.invalid" })
            #expect(coordinator.mountedSurfaceCount == 1)
        }
    }

    @Test("a throwing mounted fixture drains held opens, leases, and presentation registrations")
    func failingFixtureDrains() async throws {
        let probe = BrowserLiveTransportProbe(holdOpen: true)
        var retiredCoordinator: PresentationActivityCoordinator?
        await #expect(throws: BrowserLiveMountedError.expectedFailure) {
            try await Self.withMountedHost(probe: probe, profile: Self.profile("mounted-failure")) { _, _, coordinator, _ in
                retiredCoordinator = coordinator
                try await Self.waitForRequests(1, probe: probe)
                throw BrowserLiveMountedError.expectedFailure
            }
        }
        #expect(await probe.drained)
        #expect(await probe.requests.map(\.request.httpMethod) == ["POST", "DELETE"])
        #expect(retiredCoordinator?.mountedSurfaceCount == 0)
    }

    @Test("profile and same-identity generation changes preserve exact lease ownership")
    func sourceAndProfileReplacementRebindsDescriptor() async throws {
        let firstSocket = ScriptedGatewaySocket(), secondSocket = ScriptedGatewaySocket()
        let probe = BrowserLiveTransportProbe(echoDescriptor: true)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("mounted-first"), sockets: [firstSocket, secondSocket]) { model, state, _, _ in
            try await Self.waitForRequests(2, probe: probe)
            await secondSocket.enqueue(Self.hello())
            try await model.connectHostedGateway(profile: Self.profile("mounted-second"), token: "second-secret")
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "DELETE" && $0.request.url?.host == "mounted-first.invalid"
            }
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.url?.host == "mounted-second.invalid"
            }

            // Keep the same mounted view and display identity; only the exact
            // browser generation changes. Old cleanup may overlap new admission.
            state.display = Self.display(viewID: "view-a", generation: "generation-b")
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-Generation") == "generation-b"
            }
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "DELETE" && $0.request.url?.host == "mounted-second.invalid"
                    && $0.request.value(forHTTPHeaderField: "X-Tron-Live-Generation") == "generation-a"
            }
            let requests = await probe.requests
            let opens = requests.filter { $0.request.httpMethod == "POST" }
            try #require(opens.count == 3)
            #expect(opens.map { $0.request.url?.host } == ["mounted-first.invalid", "mounted-second.invalid", "mounted-second.invalid"])
            #expect(opens.allSatisfy { $0.request.url?.path.hasSuffix("/view-a") == true })
            #expect(String(data: opens[2].request.httpBody ?? Data(), encoding: .utf8)?.contains("generation-b") == true)
            #expect(requests.filter { $0.request.httpMethod == "GET" }.allSatisfy { $0.request.url?.path.hasSuffix("/view-a/frame") == true })
            state.mounted = false
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "DELETE" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-Generation") == "generation-b"
            }
        }
    }

    private static func hello() -> Data {
        Data("""
        {"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["browser-live-view.v1"]}
        """.utf8)
    }

    private static func profile(_ id: String) -> GatewayProfile {
        GatewayProfile(id: id, label: "Fixture", host: "\(id).invalid", port: 9847, machineId: "machine", deviceId: "device")
    }

    private static func display(viewID: String, generation: String) -> DisplayProjection {
        DisplayProjection(
            displayId: viewID, title: "Browser", altText: "Live browser viewport", kind: .browserLive,
            presentation: .init(requestedSurface: .sheet, inlineTapAction: .sheet),
            eligibleSurfaces: [.sheet], fallbackText: "Unavailable",
            liveView: .init(schema: "tron.browser-live-view.v1", viewId: viewID, generation: generation, title: "Browser", fallbackText: "Unavailable")
        )
    }

    private static func withMountedHost(
        probe: BrowserLiveTransportProbe,
        profile: GatewayProfile,
        sockets: [ScriptedGatewaySocket] = [ScriptedGatewaySocket()],
        operation: (AppModel, BrowserLiveMountedState, PresentationActivityCoordinator, BrowserLiveMountedHost) async throws -> Void
    ) async throws {
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(sockets: sockets).factory,
            browserLiveTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) }
        )
        let model = AppModel(client: client)
        let state = BrowserLiveMountedState(display: Self.display(viewID: "view-a", generation: "generation-a"))
        let coordinator = PresentationActivityCoordinator()
        var host: BrowserLiveMountedHost?
        func cleanup() async {
            // Join cleanup on success, failure and cancellation. Releasing the
            // deliberately non-cancellable transport lets late opens DELETE their
            // original leases before this fixture gives up ownership.
            let drained = await Task { @MainActor in
                state.mounted = false
                host?.dismissAndTearDown()
                await probe.finish()
                await model.teardown()
                await client.close()
                for _ in 0..<300 {
                    if coordinator.mountedSurfaceCount == 0, await probe.drained { return true }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return false
            }.value
            #expect(drained, "Mounted fixture must retire all surfaces and accepted HTTP leases")
        }
        do {
            let socket = try #require(sockets.first)
            await socket.enqueue(Self.hello())
            try await model.connectHostedGateway(profile: profile, token: "first-secret")
            let mounted = try Self.mount(state: state, model: model, coordinator: coordinator)
            host = mounted
            try await operation(model, state, coordinator, mounted)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    private static func mount(
        state: BrowserLiveMountedState,
        model: AppModel,
        coordinator: PresentationActivityCoordinator
    ) throws -> BrowserLiveMountedHost {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(
            rootView: BrowserLiveMountedRoot(state: state, model: model)
                .environment(\.tronPresentationActivityCoordinator, coordinator)
        )
        window.makeKeyAndVisible()
        return BrowserLiveMountedHost(window: window, previous: previous)
    }

    private static func waitForRequests(_ expected: Int, probe: BrowserLiveTransportProbe,
                                        matching: @Sendable (BrowserLiveTransportProbe.Recorded) -> Bool = { _ in true }) async throws {
        for _ in 0..<300 {
            if await probe.requests.filter(matching).count >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BrowserLiveMountedError.requestTimedOut(expected)
    }

    private static func waitForSurfaceCount(_ expected: Int, coordinator: PresentationActivityCoordinator) async throws {
        for _ in 0..<300 {
            if coordinator.mountedSurfaceCount == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BrowserLiveMountedError.surfaceTimedOut(expected, coordinator.mountedSurfaceCount)
    }
}

@MainActor
@Observable
private final class BrowserLiveMountedState {
    var display: DisplayProjection
    var covered = false
    var mounted = true
    var sceneActive = true
    var surface: PresentationSurfaceToken?

    init(display: DisplayProjection) { self.display = display }
}

private struct BrowserLiveMountedRoot: View {
    @Bindable var state: BrowserLiveMountedState
    let model: AppModel

    var body: some View {
        TronPresentationSurface(
            id: "mounted.browser-live",
            onMount: { state.surface = $0 }
        ) {
            if state.mounted {
                DisplaySheet(route: DisplayRoute(sessionID: "session-mounted", display: state.display))
                    .environment(model)
                    .tronManagedSheet(isPresented: $state.covered, identity: "mounted.cover") {
                        Text("Covering presentation")
                    }
            } else {
                Color.clear
            }
        }
        .environment(\.scenePhase, state.sceneActive ? .active : .background)
    }
}

@MainActor
private final class BrowserLiveMountedHost {
    let window: UIWindow
    let previous: UIWindow?

    init(window: UIWindow, previous: UIWindow?) {
        self.window = window; self.previous = previous
    }

    func dismissAndTearDown() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }
}

private enum BrowserLiveMountedError: Error, Equatable {
    case expectedFailure
    case requestTimedOut(Int)
    case surfaceTimedOut(Int, Int)
}
