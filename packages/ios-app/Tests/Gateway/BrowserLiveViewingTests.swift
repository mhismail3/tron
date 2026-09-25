import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite(.serialized)
struct BrowserLiveViewingTests {
    private static func hello(capability: Bool = true, kind: DisplayKind = .browserLive) -> Data {
        Data("""
        {"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":\(capability ? "[\"\(kind.liveViewCapability!)\"]" : "[]")}
        """.utf8)
    }
    private static func profile(_ id: String) -> GatewayProfile {
        GatewayProfile(id: id, label: "Fixture", host: "\(id).invalid", port: 9847, machineId: "machine", deviceId: "device")
    }

    @Test("an opened viewer keeps its original origin and credential across profile replacement, including cancelled cleanup", arguments: [DisplayKind.browserLive, .nativeLive])
    func originalLeaseOwnsCleanup(kind: DisplayKind) async throws {
        try await withTestWatchdog {
            let first = ScriptedGatewaySocket(), second = ScriptedGatewaySocket()
            let probe = BrowserLiveTransportProbe(kind: kind)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [first, second]).factory,
                liveViewTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
            await first.enqueue(Self.hello(kind: kind))
            _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "first-secret")
            let lease = try await client.openLiveView(kind: kind, viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first")
            let update = try await lease.frame(after: 7)
            if case .waiting = update {} else { Issue.record("Expected a waiting response") }
            await second.enqueue(Self.hello(kind: kind))
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

    @Test("same-profile socket reconnect does not replace the independent HTTP viewer", arguments: [DisplayKind.browserLive, .nativeLive])
    func sameProfileReconnectKeepsLease(kind: DisplayKind) async throws {
        try await withTestWatchdog {
            let first = ScriptedGatewaySocket(), second = ScriptedGatewaySocket()
            let probe = BrowserLiveTransportProbe(kind: kind)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [first, second]).factory,
                liveViewTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
            let profile = Self.profile("same-origin")
            await first.enqueue(Self.hello(kind: kind))
            _ = try await client.connectForLifecycle(profile: profile, token: "same-token")
            let lease = try await client.openLiveView(kind: kind, viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: profile.id)
            await second.enqueue(Self.hello(kind: kind))
            _ = try await client.connectForLifecycle(profile: profile, token: "same-token")
            if case .waiting = try await lease.frame(after: 7) {} else { Issue.record("Expected the same live lease after socket replacement") }
            await lease.close()
            let requests = await probe.requests
            #expect(requests.map(\.request.httpMethod) == ["POST", "GET", "DELETE"])
            #expect(requests.allSatisfy { $0.request.url?.host == "same-origin.invalid" })
            #expect(requests[1].request.value(forHTTPHeaderField: "X-Tron-Live-Lease") == BrowserLiveTransportProbe.leaseID)
            await client.close()
        }
    }

    @Test("a late successful open is closed, not published, after profile replacement", arguments: [DisplayKind.browserLive, .nativeLive])
    func staleOpenIsClosed(kind: DisplayKind) async throws {
        try await withTestWatchdog {
            let first = ScriptedGatewaySocket(), second = ScriptedGatewaySocket()
            let probe = BrowserLiveTransportProbe(holdOpen: true, kind: kind)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [first, second]).factory,
                liveViewTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
            await first.enqueue(Self.hello(kind: kind))
            _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "first-secret")
            let opening = Task { try await client.openLiveView(kind: kind, viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first") }
            await probe.waitForOpen()
            await second.enqueue(Self.hello(kind: kind))
            _ = try await client.connectForLifecycle(profile: Self.profile("second"), token: "second-secret")
            await probe.releaseOpen()
            await #expect(throws: CancellationError.self) { try await opening.value }
            let requests = await probe.requests
            #expect(requests.map(\.request.httpMethod) == ["POST", "DELETE"])
            #expect(requests.last?.request.url?.host == "first.invalid")
            await client.close()
        }
    }

    @Test("closing a lease fences a response already in flight", arguments: [DisplayKind.browserLive, .nativeLive])
    func closedLeaseRejectsLateFrame(kind: DisplayKind) async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket(), probe = BrowserLiveTransportProbe(holdFrame: true, kind: kind)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                liveViewTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
            await socket.enqueue(Self.hello(kind: kind))
            _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "secret")
            let lease = try await client.openLiveView(kind: kind, viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first")
            let reading = Task { try await lease.frame(after: 0) }
            await probe.waitForFrame()
            await lease.close()
            await probe.releaseFrame()
            await #expect(throws: CancellationError.self) { try await reading.value }
            #expect(await probe.requests.map(\.request.httpMethod) == ["POST", "GET", "DELETE"])
            await client.close()
        }
    }

    @Test("missing live-view capability performs no HTTP work", arguments: [DisplayKind.browserLive, .nativeLive])
    func capabilityAdmission(kind: DisplayKind) async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket(), probe = BrowserLiveTransportProbe(kind: kind)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                liveViewTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
            await socket.enqueue(Self.hello(capability: false, kind: kind))
            _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "secret")
            await #expect(throws: GatewayClient.LiveError.self) {
                try await client.openLiveView(kind: kind, viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first")
            }
            #expect(await probe.requests.isEmpty)
            await client.close()
        }
    }

    @Test("browser and native capabilities and lease schemas cannot authorize each other", arguments: [DisplayKind.browserLive, .nativeLive])
    func producerAdmission(kind: DisplayKind) async throws {
        try await withTestWatchdog {
            let other: DisplayKind = kind == .nativeLive ? .browserLive : .nativeLive
            for wrongSchema in [false, true] {
                let socket = ScriptedGatewaySocket(), probe = BrowserLiveTransportProbe(kind: other)
                let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                    liveViewTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
                await socket.enqueue(Self.hello(kind: wrongSchema ? kind : other))
                _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "secret")
                await #expect(throws: GatewayClient.LiveError.self) {
                    try await client.openLiveView(kind: kind, viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first")
                }
                // Valid but mismatched leases still need original-origin cleanup.
                #expect(await probe.requests.map(\.request.httpMethod) == (wrongSchema ? ["POST", "DELETE"] : []))
                #expect(await probe.drained)
                await client.close()
            }
        }
    }

    @Test("retired synchronous preparation drains before a replacement can decode")
    func retiredPreparationDoesNotOverlap() async throws {
        try await withTestWatchdog {
            let preparation = LiveImagePreparation()
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

    @MainActor @Test("browser and native lease frames contend on the production app-wide preparation owner")
    func frameDecodesSharePreparationOwner() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        try await withTestWatchdog {
            var frames: [GatewayClient.LiveFrame] = []
            for kind: DisplayKind in [.browserLive, .nativeLive] {
                let socket = ScriptedGatewaySocket(), probe = BrowserLiveTransportProbe(frames: [jpeg], kind: kind)
                let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                    liveViewTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) })
                await socket.enqueue(Self.hello(kind: kind))
                _ = try await client.connectForLifecycle(profile: Self.profile("first"), token: "secret")
                let lease = try await client.openLiveView(kind: kind, viewId: "view-a", generation: "generation-a", sessionID: "session-a", profileID: "first")
                let update = try await lease.frame(after: 0)
                if case .frame(let frame) = update { frames.append(frame) }
                await lease.close()
                await client.close()
            }
            try #require(frames.count == 2)
            let firstFrame = frames[0], secondFrame = frames[1]
            let (started, arrival) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let release = DispatchSemaphore(value: 0)
            let occupied = Task {
                defer { arrival.finish() }
                return try await LiveImagePreparation.shared.prepare {
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
        let frame = try GatewayClient.LiveFrame(data: jpeg, response: response())
        let image = try await frame.decode()
        #expect(image?.cgImage?.width == 1 && image?.cgImage?.height == 1)
        let mismatch = try GatewayClient.LiveFrame(data: jpeg, response: response(width: "2"))
        await #expect(throws: GatewayClient.LiveError.self) { try await mismatch.decode() }
        let corrupt = try GatewayClient.LiveFrame(data: Data("not jpeg".utf8), response: response())
        await #expect(throws: GatewayClient.LiveError.self) { try await corrupt.decode() }
        for invalid in [response(width: "2561"), response(width: "2500", height: "2500"), response(mime: "image/png")] {
            #expect(throws: GatewayClient.LiveError.self) { try GatewayClient.LiveFrame(data: jpeg, response: invalid) }
        }
        #expect(throws: GatewayClient.LiveError.self) {
            try GatewayClient.LiveFrame(data: Data(count: GatewayClient.LiveFrame.maximumEncodedBytes + 1), response: response())
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
    private let kind: DisplayKind
    private let singleUse: Bool
    private var retired = false
    private var frames: [Data]
    private var framing = false
    private var frameWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldFrames: [CheckedContinuation<Void, Never>] = []
    private var opening = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldOpens: [CheckedContinuation<Void, Never>] = []
    init(holdOpen: Bool = false, holdFrame: Bool = false, echoDescriptor: Bool = false, frames: [Data] = [],
         kind: DisplayKind = .browserLive, singleUse: Bool = false) {
        self.holdOpen = holdOpen; self.holdFrame = holdFrame; self.echoDescriptor = echoDescriptor
        self.frames = frames; self.kind = kind; self.singleUse = singleUse
    }
    func appendFrame(_ frame: Data) { frames.append(frame) }
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
            if retired {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!)
            }
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
            {"leaseId":"\(leaseID)","descriptor":{"schema":"\(kind.liveViewSchema!)","viewId":"\(descriptorViewID)","generation":"\(descriptorGeneration)","title":"Live view","fallbackText":"Unavailable"}}
            """.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!)
        }
        if request.httpMethod == "GET" {
            framing = true
            frameWaiters.forEach { $0.resume() }; frameWaiters.removeAll()
            if holdFrame && !finished { await withCheckedContinuation { heldFrames.append($0) } }
            if !frames.isEmpty {
                let after = Int(request.value(forHTTPHeaderField: "X-Tron-Live-After") ?? "0") ?? 0
                if frames.indices.contains(after) {
                    let dimensions = UIImage(data: frames[after]).map { (Int($0.size.width), Int($0.size.height)) } ?? (48, 36)
                    return (frames[after], HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "image/jpeg", "X-Tron-Live-Width": String(dimensions.0),
                                       "X-Tron-Live-Height": String(dimensions.1), "X-Tron-Live-Sequence": String(after + 1)])!)
                }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil,
                    headerFields: ["X-Tron-Live-State": "unchanged"])!)
            }
        }
        if request.httpMethod == "DELETE", let leaseID = request.value(forHTTPHeaderField: "X-Tron-Live-Lease") {
            outstandingLeases.remove(leaseID)
            if singleUse && outstandingLeases.isEmpty { retired = true }
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
    @Test("native frames use the existing sheet/floating renderer and retired descriptors never select another window", arguments: [false, true])
    func nativeRetirementDoesNotSelectReplacement(floating: Bool) async throws {
        let probe = BrowserLiveTransportProbe(echoDescriptor: true,
            frames: [Self.jpeg(.green, size: CGSize(width: 9, height: 16))], kind: .nativeLive, singleUse: true)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("native-retirement"), floating: floating, kind: .nativeLive) { _, state, _, host in
            try await Self.waitForRequests(2, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "1"
            }
            #expect(Self.greenPixelCount(in: host.window) > 50)
            #expect(await probe.requests.filter { $0.request.httpMethod == "POST" }.count == 1)
            if floating { _ = try await Self.waitForPanel(host) { $0.height > $0.width } }
            state.sceneActive = false
            try await Self.waitForRequests(1, probe: probe) { $0.request.httpMethod == "DELETE" }
            let stopped = await probe.requests.count
            try await Task.sleep(for: .milliseconds(350))
            #expect(await probe.requests.count == stopped)
            #expect(Self.greenPixelCount(in: host.window) == 0)

            // The same retained descriptor may be unavailable after retirement.
            // The renderer must settle once, never infer or select a new window.
            state.sceneActive = true
            try await Self.waitForRequests(2, probe: probe) { $0.request.httpMethod == "POST" }
            try await Task.sleep(for: .milliseconds(450))
            let requests = await probe.requests
            #expect(requests.count == stopped + 1)
            #expect(Self.greenPixelCount(in: host.window) == 0)
            let opens = requests.filter { $0.request.httpMethod == "POST" }
            #expect(opens.allSatisfy { $0.request.url?.path == "/v1/sessions/session-mounted/live-views/view-a" })
            #expect(opens.allSatisfy { String(data: $0.request.httpBody ?? Data(), encoding: .utf8)?.contains("generation-a") == true })
        }
    }

    @Test("decoded frames paint and keep one lease across loading and image transitions", arguments: [DisplayKind.browserLive, .nativeLive])
    func decodedFramesKeepMountedLease(kind: DisplayKind) async throws {
        for floating in [false, true] {
            let probe = BrowserLiveTransportProbe(echoDescriptor: true, frames: [Self.jpeg(.red), Self.jpeg(.green)], kind: kind)
            try await Self.withMountedHost(probe: probe, profile: Self.profile("painted-frames"), floating: floating, kind: kind) { _, state, _, host in
                // Advancing the public after-sequence proves that the actual
                // renderer consumed both JPEGs, not merely that GET was called.
                try await Self.waitForRequests(2, probe: probe) {
                    $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "2"
                }
                let requests = await probe.requests
                #expect(requests.filter { $0.request.httpMethod == "POST" }.count == 1)
                #expect(requests.filter { $0.request.httpMethod == "DELETE" }.isEmpty)
                #expect(Self.greenPixelCount(in: host.window) > 50, "The second JPEG must remain painted in the mounted viewer")

                state.sceneActive = false
                try await Self.waitForRequests(1, probe: probe) { $0.request.httpMethod == "DELETE" }
                let stopped = await probe.requests.count
                try await Task.sleep(for: .milliseconds(350))
                #expect(await probe.requests.count == stopped)
                state.sceneActive = true
                try await Self.waitForRequests(4, probe: probe) {
                    $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "2"
                }
                let reopened = await probe.requests
                #expect(reopened.filter { $0.request.httpMethod == "POST" }.count == 2)
                #expect(Self.greenPixelCount(in: host.window) > 50)
            }
        }
    }

    @Test("a terminal decode failure closes once without remounting into an open loop")
    func failedFrameDoesNotReopen() async throws {
        let probe = BrowserLiveTransportProbe(echoDescriptor: true, frames: [Data("invalid JPEG".utf8)])
        try await Self.withMountedHost(probe: probe, profile: Self.profile("failed-frame")) { _, _, _, _ in
            try await Self.waitForRequests(1, probe: probe) { $0.request.httpMethod == "DELETE" }
            try await Task.sleep(for: .milliseconds(450))
            let methods = await probe.requests.map(\.request.httpMethod)
            #expect(methods == ["POST", "GET", "DELETE"])
        }
    }

    private static func jpeg(_ color: UIColor, size: CGSize = CGSize(width: 48, height: 36)) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .jpegData(withCompressionQuality: 0.8) { context in
                color.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
    }

    private static func greenPixelCount(in window: UIWindow) -> Int {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return 0 }
        let width = 64, height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] < 60 && pixels[$0 + 1] > 200 && pixels[$0 + 2] < 60 && pixels[$0 + 3] > 230
        }.count
    }

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

    @Test("native app and exact scene activity retire and reopen without a SwiftUI scene-phase change", arguments: [DisplayKind.browserLive, .nativeLive])
    func nativeActivityStopsAndReopens(kind: DisplayKind) async throws {
        for applicationEvent in [true, false] {
            let probe = BrowserLiveTransportProbe(holdFrame: true, kind: kind)
            try await Self.withMountedHost(probe: probe, profile: Self.profile("native-activity"), kind: kind) { _, _, _, host in
                try await Self.waitForRequests(2, probe: probe)
                let scene = try #require(host.window.windowScene)
                let object: AnyObject = applicationEvent ? UIApplication.shared : scene
                let inactive = applicationEvent ? UIApplication.willResignActiveNotification : UIScene.willDeactivateNotification
                let active = applicationEvent ? UIApplication.didBecomeActiveNotification : UIScene.didActivateNotification
                // Real mounted notification callbacks, not OS backgrounding. The
                // injected SwiftUI phase stays active to isolate this boundary.
                NotificationCenter.default.post(name: inactive, object: object)
                await probe.releaseFrame()
                try await Self.waitForRequests(3, probe: probe)
                let stopped = await probe.requests.map(\.request.httpMethod)
                #expect(stopped == ["POST", "GET", "DELETE"])
                try await Task.sleep(for: .milliseconds(350))
                #expect(await probe.requests.count == 3)
                NotificationCenter.default.post(name: active, object: object)
                try await Self.waitForRequests(5, probe: probe)
                let reopened = await probe.requests
                let methods = reopened.map(\.request.httpMethod)
                let originalOnly = reopened.allSatisfy { $0.request.url?.path.contains("view-a") == true }
                #expect(methods == ["POST", "GET", "DELETE", "POST", "GET"])
                #expect(originalOnly)
            }
        }
    }

    @Test("coalesced native inactivity and activation reopen once and preserve geometry across renderer replacement", arguments: [DisplayKind.browserLive, .nativeLive])
    func coalescedNativeActivityReopens(kind: DisplayKind) async throws {
        for applicationEvent in [true, false] {
            let probe = BrowserLiveTransportProbe(echoDescriptor: true,
                frames: [Self.jpeg(.green, size: CGSize(width: 9, height: 16))], kind: kind)
            try await Self.withMountedHost(probe: probe, profile: Self.profile("coalesced-activity"), floating: true, kind: kind) { _, state, _, host in
                try await Self.waitForRequests(1, probe: probe) {
                    $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "1"
                }
                let firstRequests = await probe.requests
                let firstLease = try #require(firstRequests.first { $0.request.httpMethod == "GET" }?.request.value(forHTTPHeaderField: "X-Tron-Live-Lease"))
                let panel = try #require(host.floatingPanel)
                let scene = try #require(host.window.windowScene)
                let object: AnyObject = applicationEvent ? UIApplication.shared : scene
                let inactive = applicationEvent ? UIApplication.willResignActiveNotification : UIScene.willDeactivateNotification
                let active = applicationEvent ? UIApplication.didBecomeActiveNotification : UIScene.didActivateNotification
                // No await between native callbacks: SwiftUI sees active before
                // and after this turn. Only the native generation can retire the
                // original task; a captured active Bool cannot detect the gap.
                NotificationCenter.default.post(name: inactive, object: object)
                NotificationCenter.default.post(name: active, object: object)
                try await Self.waitForRequests(1, probe: probe) {
                    $0.request.httpMethod == "DELETE" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") == firstLease
                }
                try await Self.waitForRequests(1, probe: probe) {
                    $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") != firstLease
                        && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "1"
                }
                #expect(await probe.requests.filter { $0.request.httpMethod == "POST" }.count == 2)
                _ = try await Self.waitForPanel(host) { $0.height > $0.width }
                #expect(Self.greenPixelCount(in: host.window) > 50)

                // The retired renderer now has a higher native generation than
                // the replacement on return. Deliver different geometry only
                // while the sheet owns viewing, so stale portrait sizing cannot
                // satisfy the replacement's wide-frame assertion.
                let floatingLeases = Set(await probe.requests.compactMap { $0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") })
                state.sheetRoute = state.floatingRoute
                try await Self.waitForRequests(1, probe: probe) {
                    $0.request.httpMethod == "GET" && !floatingLeases.contains($0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") ?? "")
                        && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "1"
                }
                #expect(Self.greenPixelCount(in: host.window) > 50)
                await probe.appendFrame(Self.jpeg(.green, size: CGSize(width: 32, height: 9)))
                try await Self.waitForRequests(1, probe: probe) {
                    $0.request.httpMethod == "GET" && !floatingLeases.contains($0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") ?? "")
                        && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "2"
                }
                let sheetLeases = Set(await probe.requests.compactMap { $0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") })
                state.sheetRoute = nil
                try await Self.waitForRequests(1, probe: probe) {
                    $0.request.httpMethod == "GET" && !sheetLeases.contains($0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") ?? "")
                        && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "2"
                }
                _ = try await Self.waitForPanel(host) { $0.width > $0.height }
                #expect(host.floatingPanel === panel)
                #expect(Self.greenPixelCount(in: host.window) > 50)
                #expect(await probe.requests.filter { $0.request.httpMethod == "POST" }.count == 4)
            }
        }
    }

    @Test("an active DisplaySheet polls, while a covered retained host performs no work and joins cleanup", arguments: [DisplayKind.browserLive, .nativeLive])
    func coveredRetainedHostStopsPolling(kind: DisplayKind) async throws {
        let probe = BrowserLiveTransportProbe(holdFrame: true, kind: kind)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("mounted"), kind: kind) { _, state, coordinator, host in
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

    @Test("a dismissed host fences an in-flight open and the late response closes its original lease", arguments: [DisplayKind.browserLive, .nativeLive])
    func dismissedHostFencesOpen(kind: DisplayKind) async throws {
        let probe = BrowserLiveTransportProbe(holdOpen: true, kind: kind)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("mounted-open"), kind: kind) { _, state, coordinator, _ in
            try await Self.waitForRequests(1, probe: probe)
            state.mounted = false
            await probe.releaseOpen()
            try await Self.waitForRequests(2, probe: probe)
            #expect(await probe.requests.map(\.request.httpMethod) == ["POST", "DELETE"])
            #expect(await probe.requests.allSatisfy { $0.request.url?.host == "mounted-open.invalid" })
            #expect(coordinator.mountedSurfaceCount == 1)
        }
    }

    @Test("profile and same-identity generation changes preserve exact lease ownership", arguments: [DisplayKind.browserLive, .nativeLive])
    func sourceAndProfileReplacementRebindsDescriptor(kind: DisplayKind) async throws {
        let firstSocket = ScriptedGatewaySocket(), secondSocket = ScriptedGatewaySocket()
        let probe = BrowserLiveTransportProbe(echoDescriptor: true, kind: kind)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("mounted-first"), kind: kind, sockets: [firstSocket, secondSocket]) { model, state, _, _ in
            try await Self.waitForRequests(2, probe: probe)
            await secondSocket.enqueue(Self.hello(kind: kind))
            try await model.connectHostedGateway(profile: Self.profile("mounted-second"), token: "second-secret")
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "DELETE" && $0.request.url?.host == "mounted-first.invalid"
            }
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.url?.host == "mounted-second.invalid"
            }

            // Keep the same mounted view and display identity; only the exact
            // producer generation changes. Old cleanup may overlap new admission.
            state.display = Self.display(viewID: "view-a", generation: "generation-b", kind: kind)
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

    @Test("floating expansion retires the covered lease and restores only the original browser")
    func floatingExpansionAndReopen() async throws {
        let probe = BrowserLiveTransportProbe(echoDescriptor: true, frames: [Self.jpeg(.green)])
        try await Self.withMountedHost(probe: probe, profile: Self.profile("floating"), floating: true) { _, state, coordinator, host in
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "1"
            }
            #expect(Self.greenPixelCount(in: host.window) > 50)
            let firstRequests = await probe.requests
            let initialLease = firstRequests.first { $0.request.httpMethod == "GET" }?.request.value(forHTTPHeaderField: "X-Tron-Live-Lease")
            let first = try #require(initialLease)
            let original = try #require(state.floatingRoute)
            state.sheetRoute = original
            try await Self.waitForRequests(1, probe: probe) { $0.request.httpMethod == "DELETE" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") == first }
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") != first
                    && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "1"
            }
            #expect(Self.greenPixelCount(in: host.window) > 50)
            let cut = await probe.requests.count
            try await Task.sleep(for: .milliseconds(350))
            let afterCoverage = await probe.requests
            let originalLeaseQuiescent = afterCoverage.dropFirst(cut).allSatisfy { $0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") != first }
            #expect(originalLeaseQuiescent)
            let poppedOut = try #require(host.marker("floating-popped-out"))
            let panel = try #require(host.floatingPanel)
            let iconFrame = poppedOut.convert(poppedOut.bounds, to: panel)
            #expect(abs(iconFrame.midX - panel.bounds.midX) <= 2)
            #expect(abs(iconFrame.midY - panel.bounds.midY) <= 2)
            state.sheetRoute = nil
            var observedDismissal = false
            for _ in 0..<180 {
                try await DisplayFrameScheduler.displayLink.nextFrame()
                if coordinator.activity(for: state.surface).allowsPresentationPublication { break }
                observedDismissal = true
                #expect(host.marker("floating-popped-out") != nil, "Keep the icon while the native sheet is still dismissing")
            }
            #expect(observedDismissal)
            try await Self.waitForRequests(3, probe: probe) { $0.request.httpMethod == "POST" }
            #expect(state.floatingRoute == original)
            let opens = await probe.requests.filter { $0.request.httpMethod == "POST" }
            #expect(opens.count == 3)
            let originalViewOnly = opens.allSatisfy { $0.request.url?.path.hasSuffix("/view-a") == true }
            let originalGenerationOnly = opens.allSatisfy { String(data: $0.request.httpBody ?? Data(), encoding: .utf8)?.contains("generation-a") == true }
            #expect(originalViewOnly)
            #expect(originalGenerationOnly)
            #expect(host.marker("floating-popped-out") == nil)
        }
    }

    @Test("admitted portrait and wide frames resize one mounted panel without restarting its lease", arguments: [DisplayKind.browserLive, .nativeLive])
    func floatingFrameGeometryAdaptsWithoutRemounting(kind: DisplayKind) async throws {
        let probe = BrowserLiveTransportProbe(echoDescriptor: true, frames: [
            Self.jpeg(.red, size: CGSize(width: 9, height: 16))
        ], kind: kind)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("adaptive-geometry"), floating: true, kind: kind) { _, state, _, host in
            _ = try await Self.waitForPanel(host) { $0.height > $0.width }
            let panel = try #require(host.floatingPanel)
            let bounds = try #require(host.marker("live-floating-container"))
            let container = bounds.convert(bounds.bounds, to: host.window)
            panel.move?(.topLeading)
            let portrait = try await Self.waitForPanel(host) { $0.height > $0.width && abs($0.minX - container.minX - 8) <= 1 }
            Self.attachSimulatorImage(host.window, name: "simulator-live-portrait.png")

            let grab = CGPoint(x: 30, y: 30)
            let heldPoint = CGPoint(x: portrait.minX + grab.x, y: portrait.minY + grab.y)
            let start = CGPoint(x: heldPoint.x - container.minX, y: heldPoint.y - container.minY)
            panel.pan?(.init(state: .began, location: start, locationInWindow: grab, velocity: .zero))
            panel.pan?(.init(state: .changed, location: start, locationInWindow: grab, velocity: .zero))
            // The next frame is not available until the first frame is actually
            // laid out and the drag is active. GET arrival alone is not an oracle.
            await probe.appendFrame(Self.jpeg(.green, size: CGSize(width: 32, height: 9)))
            let wide = try await Self.waitForPanel(host) { $0.width > $0.height }
            #expect(panel === host.floatingPanel)
            #expect(abs(wide.minX + grab.x - heldPoint.x) <= 2)
            #expect(abs(wide.minY + grab.y - heldPoint.y) <= 2)
            #expect(Self.greenPixelCount(in: host.window) > 50)
            Self.attachSimulatorImage(host.window, name: "simulator-live-wide.png")

            // Model the native available-area contraction while the same finger
            // remains down; no subsequent pan sample is allowed to repair it.
            state.floatingHeight = 180
            for _ in 0..<8 { try await DisplayFrameScheduler.displayLink.nextFrame() }
            let contracted = panel.convert(panel.bounds, to: host.window)
            #expect(panel === host.floatingPanel)
            #expect(abs(contracted.minX + grab.x - heldPoint.x) <= 2)
            #expect(abs(contracted.minY + grab.y - heldPoint.y) <= 2)
            #expect(await probe.requests.filter { $0.request.httpMethod == "POST" }.count == 1)
            panel.pan?(.init(state: .cancelled, location: .zero, locationInWindow: grab, velocity: .zero))

            let initialRequests = await probe.requests
            let firstLease = try #require(initialRequests.first { $0.request.httpMethod == "GET" }?.request.value(forHTTPHeaderField: "X-Tron-Live-Lease"))
            // Resume immediately at the transport retirement boundary. DELETE
            // does not imply a new display frame: a phase callback that feeds
            // back into the task ID can suppress this rapid resume permanently.
            state.sceneActive = false
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "DELETE" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") == firstLease
            }
            state.sceneActive = true
            try await Self.waitForRequests(2, probe: probe) { $0.request.httpMethod == "POST" }
            try await Self.waitForRequests(2, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-Lease") != firstLease
                    && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "2"
            }
            #expect(await probe.requests.filter { $0.request.httpMethod == "POST" }.count == 2)
            #expect(Self.greenPixelCount(in: host.window) > 50)
            state.floatingHeight = 320
            state.sheetRoute = state.floatingRoute
            try await Self.waitForRequests(3, probe: probe) { $0.request.httpMethod == "POST" }
            await probe.appendFrame(Self.jpeg(.blue, size: CGSize(width: 18, height: 32)))
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "3"
            }
            state.sheetRoute = nil
            try await Self.waitForRequests(4, probe: probe) { $0.request.httpMethod == "POST" }
            try await Self.waitForRequests(2, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "3"
            }
            _ = try await Self.waitForPanel(host) { $0.height > $0.width }
            #expect(panel === host.floatingPanel)
            #expect(Self.greenPixelCount(in: host.window) == 0)
        }
    }

    @Test("nonzero layout changes keep the painted browser on one lease")
    func floatingResizePreservesViewing() async throws {
        let probe = BrowserLiveTransportProbe(echoDescriptor: true, frames: [Self.jpeg(.green)])
        try await Self.withMountedHost(probe: probe, profile: Self.profile("resizing"), floating: true) { _, state, _, host in
            try await Self.waitForRequests(1, probe: probe) {
                $0.request.httpMethod == "GET" && $0.request.value(forHTTPHeaderField: "X-Tron-Live-After") == "1"
            }
            let panel = try #require(host.floatingPanel)
            for height in [CGFloat(180), 100, 320] {
                state.floatingHeight = height
                try await Task.sleep(for: .milliseconds(350))
                #expect(host.floatingPanel === panel)
                #expect(Self.greenPixelCount(in: host.window) > 20)
            }
            let requests = await probe.requests
            #expect(requests.filter { $0.request.httpMethod == "POST" }.count == 1)
            #expect(!requests.contains { $0.request.httpMethod == "DELETE" })
        }
    }

    @Test("replacement windows retire old placement callbacks rather than moving their successor")
    func floatingReplacementRetiresPlacement() async throws {
        let probe = BrowserLiveTransportProbe(echoDescriptor: true)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("replacement"), floating: true) { _, state, _, host in
            try await Self.waitForRequests(1, probe: probe) { $0.request.httpMethod == "GET" }
            let original = try #require(host.floatingPanel)
            let delayedMove = original.move
            state.floatingRoute = DisplayRoute(sessionID: "session-mounted", display: Self.display(viewID: "view-b", generation: "generation-b"))
            try await Self.waitForRequests(2, probe: probe) { $0.request.httpMethod == "POST" }
            // New transport admission precedes the outgoing native window's
            // animated retirement. Select the successor only after that exact
            // marker is detached, not after an assumed animation duration.
            for _ in 0..<180 where original.window != nil || original.move != nil {
                try await DisplayFrameScheduler.displayLink.nextFrame()
            }
            #expect(original.window == nil)
            let replacement = try #require(host.floatingPanel)
            #expect(replacement !== original)
            #expect(original.move == nil)
            let frame = replacement.convert(replacement.bounds, to: host.window)
            delayedMove?(.bottomLeading)
            try await Task.sleep(for: .milliseconds(350))
            #expect(replacement.convert(replacement.bounds, to: host.window) == frame)
            #expect(state.floatingRoute?.display.liveView?.viewId == "view-b")
        }
    }

    @Test("a zero-area floating panel keeps its route but does no viewing work")
    func zeroAreaFloatingRetiresViewing() async throws {
        let probe = BrowserLiveTransportProbe(echoDescriptor: true)
        try await Self.withMountedHost(probe: probe, profile: Self.profile("floating-size"), floating: true) { _, state, _, _ in
            try await Self.waitForRequests(1, probe: probe) { $0.request.httpMethod == "GET" }
            let original = state.floatingRoute
            state.floatingHeight = 0
            try await Self.waitForRequests(1, probe: probe) { $0.request.httpMethod == "DELETE" }
            let stopped = await probe.requests.count
            try await Task.sleep(for: .milliseconds(350))
            #expect(await probe.requests.count == stopped)
            #expect(state.floatingRoute == original)
            state.floatingHeight = 320
            try await Self.waitForRequests(2, probe: probe) { $0.request.httpMethod == "POST" }
        }
    }

    private static func hello(kind: DisplayKind = .browserLive) -> Data {
        Data("""
        {"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["\(kind.liveViewCapability!)"]}
        """.utf8)
    }

    private static func profile(_ id: String) -> GatewayProfile {
        GatewayProfile(id: id, label: "Fixture", host: "\(id).invalid", port: 9847, machineId: "machine", deviceId: "device")
    }

    private static func display(viewID: String, generation: String, kind: DisplayKind = .browserLive) -> DisplayProjection {
        DisplayProjection(
            displayId: viewID, title: "Live view", altText: "Live viewport", kind: kind,
            presentation: .init(requestedSurface: .sheet, inlineTapAction: .sheet),
            eligibleSurfaces: [.sheet, .floating], fallbackText: "Unavailable",
            liveView: .init(schema: kind.liveViewSchema!, viewId: viewID, generation: generation, title: "Live view", fallbackText: "Unavailable")
        )
    }

    private static func withMountedHost(
        probe: BrowserLiveTransportProbe,
        profile: GatewayProfile,
        floating: Bool = false,
        kind: DisplayKind = .browserLive,
        sockets: [ScriptedGatewaySocket] = [ScriptedGatewaySocket()],
        operation: (AppModel, BrowserLiveMountedState, PresentationActivityCoordinator, BrowserLiveMountedHost) async throws -> Void
    ) async throws {
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(sockets: sockets).factory,
            liveViewTransport: BoundedHTTPDataTransport { request, maximum in await probe.respond(request, maximum) }
        )
        let model = AppModel(client: client)
        let state = BrowserLiveMountedState(display: Self.display(viewID: "view-a", generation: "generation-a", kind: kind), floating: floating)
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
            await socket.enqueue(Self.hello(kind: kind))
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

    private static func waitForRequests(_ expected: Int, probe: BrowserLiveTransportProbe, line: Int = #line,
                                        matching: @Sendable (BrowserLiveTransportProbe.Recorded) -> Bool = { _ in true }) async throws {
        for _ in 0..<300 {
            if await probe.requests.filter(matching).count >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await probe.requests.map {
            "\($0.request.httpMethod ?? "?") after=\($0.request.value(forHTTPHeaderField: "X-Tron-Live-After") ?? "-")"
        }
        throw BrowserLiveMountedError.requestTimedOut(expected, line, requests)
    }

    private static func waitForPanel(_ host: BrowserLiveMountedHost, matching: (CGRect) -> Bool) async throws -> CGRect {
        for _ in 0..<180 {
            try await DisplayFrameScheduler.displayLink.nextFrame()
            host.window.layoutIfNeeded()
            if let panel = host.floatingPanel {
                let frame = panel.convert(panel.bounds, to: host.window)
                if matching(frame) { return frame }
            }
        }
        Issue.record("The admitted frame did not reach the expected native panel geometry")
        throw BrowserLiveMountedError.expectedFailure
    }

    private static func attachSimulatorImage(_ window: UIWindow, name: String) {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let data = image.pngData() { Attachment.record(data, named: name) }
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
    let floatingMode: Bool
    var floatingHeight: CGFloat = 320
    let containerProbeIdentity = UUID()
    var floatingRoute: DisplayRoute?
    var sheetRoute: DisplayRoute?

    init(display: DisplayProjection, floating: Bool = false) {
        self.display = display
        floatingMode = floating
        if floating { floatingRoute = DisplayRoute(sessionID: "session-mounted", display: display) }
    }
}

private struct BrowserLiveMountedRoot: View {
    @Bindable var state: BrowserLiveMountedState
    let model: AppModel

    var body: some View {
        TronPresentationSurface(
            id: "mounted.browser-live",
            onMount: { state.surface = $0 }
        ) {
            if state.mounted, state.floatingMode {
                ChatFloatingDisplayHost(route: $state.floatingRoute, onOpenSheet: { state.sheetRoute = $0 })
                    .frame(height: state.floatingHeight)
                    .background(ChatHostedNativeRowProbe(physicalID: "live-floating-container",
                        semanticID: "live-floating-container", identity: state.containerProbeIdentity))
                    .environment(model)
                    .tronManagedSheet(item: $state.sheetRoute, identity: { $0.sheetPresentationID }) { route in
                        DisplaySheet(route: route).environment(model)
                    }
            } else if state.mounted {
                DisplaySheet(route: DisplayRoute(sessionID: "session-mounted", display: state.display))
                    .environment(model)
                    .tronManagedSheet(isPresented: $state.covered, identity: "mounted.cover") {
                        Text("Covering presentation")
                    }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var nativeViews: [UIView] {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        guard let root = window.rootViewController?.view else { return [] }
        return descendants(root)
    }

    var floatingPanel: FloatingDisplayHostedMarker? { nativeViews.compactMap { $0 as? FloatingDisplayHostedMarker }.first }
    func marker(_ id: String) -> ChatHostedNativeRowMarker? {
        nativeViews.compactMap { $0 as? ChatHostedNativeRowMarker }.first { $0.physicalID == id }
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
    case requestTimedOut(Int, Int, [String])
    case surfaceTimedOut(Int, Int)
}
