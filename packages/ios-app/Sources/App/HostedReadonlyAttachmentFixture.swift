#if HOSTED_TEST
import AVFoundation
import CoreVideo
import SwiftUI
import TronMobileCore

/// Actual chat/preview surfaces; only the Gateway/media bytes and native
/// evidence recorder are scripted. Scene transitions use the production owner.
struct HostedReadonlyAttachmentFixture: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    @State private var ready = false
    @State private var sessionID = "readonly-session"
    @State private var counters = "opens:0 fetches:0 released:0"
    @State private var native = "none"
    @State private var before = "none"
    @State private var hasBackgrounded = false
    @State private var poisonPublished = false
    private let gateway: ReadonlyAttachmentGateway
    private let scenario: String
    private let profile = GatewayProfile(id: "readonly-original", label: "Readonly fixture", host: "original.example.test", port: 9847, machineId: "readonly-machine")
    private let replacement = GatewayProfile(id: "readonly-replacement", label: "Replacement fixture", host: "replacement.example.test", port: 9847, machineId: "readonly-replacement-machine")

    init() {
        let args = ProcessInfo.processInfo.arguments
        let scenario = args.drop(while: { $0 != "-readonly-preview-scenario" }).dropFirst().first ?? "image"
        self.scenario = scenario
        let gateway = ReadonlyAttachmentGateway(scenario: scenario)
        self.gateway = gateway
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-only-token")
        try! profiles.save(replacement, token: "fixture-only-replacement-token", selecting: false)
        _model = State(initialValue: AppModel(
            client: GatewayClient(socketFactory: GatewaySocketFactory { request in
                ReadonlyAttachmentSocket(gateway: gateway, replacement: request.url?.host == "replacement.example.test")
            }), profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "readonly-preview-fixture")),
            chatMediaFetch: { identity in await gateway.fetch(identity) }
        ))
        _model.wrappedValue.hostedDisplayArtifactFile = { id, sessionID, profileID, maximumBytes, expectedBytes in
            try await gateway.stageDisplayArtifact(id: id, maximumBytes: maximumBytes, expectedBytes: expectedBytes)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ready {
                    ChatView(sessionID: sessionID)
                        .id("\(model.knowledgeDestinationIdentity):\(sessionID)")
                }
                Text(counters).font(.caption2).accessibilityIdentifier("fixture.preview-counts")
                Text(native).font(.caption2).accessibilityIdentifier("fixture.preview-native")
                Text(poisonPublished ? "poison:true" : "poison:false").font(.caption2).accessibilityIdentifier("fixture.preview-poison")
                Text(before).font(.caption2).accessibilityIdentifier("fixture.preview-before")
                Text("\(model.connectionState) socket:\(model.knowledgePresentationIdentity.connectionID.map(String.init) ?? "none")")
                    .font(.caption2).accessibilityIdentifier("fixture.preview-connection")
            }
        }
        .environment(model)
        .tronPresentation()
        .preferredColorScheme(scenario.contains("-light") ? .light : .dark)
        .background(ReadonlyPreviewNativeRecorder { value in
            if value.contains("height:640") || value == "file retired:true" { poisonPublished = true }
            if native != value { native = value }
        }.frame(width: 0, height: 0))
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                before = native
                hasBackgrounded = true
                model.enteredBackground()
                Task {
                    if scenario.contains("replace-profile") { await model.switchGateway(replacement) }
                    if scenario.contains("replace-session") { sessionID = "readonly-replacement-session" }
                    if !scenario.contains("foreground-held") { await gateway.releaseHeldFetch() }
                }
            case .inactive: model.becameInactive()
            case .active: model.becameActive()
            @unknown default: break
            }
        }
        .onChange(of: model.connectionState) { _, state in
            guard scenario.contains("foreground-held"), state == .connected, hasBackgrounded else { return }
            Task {
                await model.chatMedia.hostedWaitForPreviewAdmissionCount(2)
                await gateway.releaseHeldFetch()
            }
        }
        .task { for await value in gateway.updates() { counters = value } }
        .task {
            do {
                if scenario.contains("display-video") { try await gateway.prepareVideo() }
                try await model.connectHostedGateway(profile: profile, token: "fixture-only-token")
                ready = true
            }
            catch { counters = "fixture-error:\(error.localizedDescription)" }
        }
    }
}

private actor ReadonlyAttachmentGateway {
    private let scenario: String
    private var videoArtifactID: String?
    private var opens = 0
    private var fetches = 0
    private var released = 0
    private var imageFetches = 0
    private var fileFetches = 0
    private var held = 0
    private var heldFetch: CheckedContinuation<Void, Never>?
    private var continuations: [AsyncStream<String>.Continuation] = []
    private let image: Data
    private let poison: Data
    private let file: Data
    private var displayRows: [TranscriptItem] = []
    private var videoData: Data?

    @MainActor init(scenario: String) {
        self.scenario = scenario
        var rows = try! JSONSerialization.jsonObject(with: HostedChatDisplayFixture.imageTranscriptData) as! [[String: Any]]
        if scenario.contains("display-file") {
            var display = rows[1]["display"] as! [String: Any]
            display["kind"] = "text"; display["title"] = "Readonly display file"
            display["altText"] = "Readonly display file"
            display["eligibleSurfaces"] = ["sheet", "inline"]
            display["presentation"] = ["requestedSurface": "sheet", "inlineTapAction": "sheet"]
            var artifact = display["artifact"] as! [String: Any]
            artifact["kind"] = "text"; artifact["name"] = "readonly.txt"; artifact["mimeType"] = "text/plain"
            display["artifact"] = artifact; rows[1]["display"] = display
        } else if scenario.contains("display-video") {
            var display = rows[1]["display"] as! [String: Any]
            display["kind"] = "video"
            display["title"] = "Inline video fixture"
            display["altText"] = "A small hosted video fixture."
            display["eligibleSurfaces"] = ["sheet", "inline", "floating"]
            display["presentation"] = ["requestedSurface": "inline", "inlineTapAction": "sheet"]
            var artifact = display["artifact"] as! [String: Any]
            artifact["kind"] = "video"; artifact["name"] = "fixture.mp4"; artifact["mimeType"] = "video/mp4"
            display["artifact"] = artifact; rows[1]["display"] = display
        }
        if !scenario.contains("display-video") {
            displayRows = try! JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: rows))
        }
        image = Self.image(height: 320)
        poison = Self.image(height: 640)
        file = Data((0..<300).map { "Readonly fixture row \($0): preserved native selection and viewport." }.joined(separator: "\n").utf8)
    }
    @MainActor private static func image(height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 160, height: height), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: height / 2))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: height / 2, width: 160, height: height / 2))
        }.pngData()!
    }
    nonisolated func updates() -> AsyncStream<String> {
        AsyncStream { continuation in Task { await self.add(continuation) } }
    }
    private func add(_ continuation: AsyncStream<String>.Continuation) { continuations.append(continuation); publish() }
    private func publish() { continuations.forEach { $0.yield("opens:\(opens) fetches:\(fetches) released:\(released) held:\(held)") } }
    @MainActor private static func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? URLError(.cannotCreateFile) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<300 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let pixel = buffer else { throw URLError(.cannotCreateFile) }
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for row in 0..<64 {
                for column in 0..<64 {
                    let offset = row * stride + column * 4
                    // A hard vertical edge makes the hosted screenshot sensitive to blur.
                    let isLeftBand = column < 32
                    base[offset] = isLeftBand ? 224 : 32
                    base[offset + 1] = isLeftBand ? 220 : 48
                    base[offset + 2] = isLeftBand ? 32 : 224
                    base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw writer.error ?? URLError(.cannotCreateFile)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? URLError(.cannotCreateFile) }
    }
    func releaseHeldFetch() { heldFetch?.resume(); heldFetch = nil }
    func prepareVideo() async throws {
        guard videoData == nil else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "readonly-display-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try await Self.writeVideo(to: file)
        let bytes = try Data(contentsOf: file)
        videoData = bytes

        let fixtureData = await MainActor.run { HostedChatDisplayFixture.imageTranscriptData }
        var rows = try JSONSerialization.jsonObject(with: fixtureData) as! [[String: Any]]
        var display = rows[1]["display"] as! [String: Any]
        display["kind"] = "video"
        display["title"] = "Inline video fixture"
        display["caption"] = "A short generated MP4 for the hosted display sheet journey."
        display["altText"] = "A small hosted video fixture."
        display["fallbackText"] = "A small hosted video fixture."
        display["eligibleSurfaces"] = ["sheet", "inline", "floating"]
        display["presentation"] = ["requestedSurface": "inline", "inlineTapAction": "sheet"]
        var artifact = display["artifact"] as! [String: Any]
        artifact["kind"] = "video"
        artifact["name"] = "fixture.mp4"
        artifact["mimeType"] = "video/mp4"
        artifact["size"] = bytes.count
        display["artifact"] = artifact
        videoArtifactID = artifact["id"] as? String
        rows[1]["display"] = display
        displayRows = try JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    func stageDisplayArtifact(id: String, maximumBytes: Int, expectedBytes: Int64) throws -> URL {
        guard id == videoArtifactID, let videoData,
              videoData.count <= maximumBytes, Int64(videoData.count) == expectedBytes else {
            throw URLError(.cannotDecodeContentData)
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "readonly-display-stage-\(UUID().uuidString)")
        do { try videoData.write(to: destination); return destination }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    func fetch(_ identity: ChatMediaIdentity) async -> ChatMediaPayload {
        fetches += 1
        let isFile = identity.blobID == "readonly-file" || scenario.contains("display-file")
        if isFile { fileFetches += 1 } else { imageFetches += 1 }
        publish()
        let holdsThisPayload = isFile ? scenario.contains("file-held") && fileFetches == 2 : scenario.contains("held") && imageFetches == 2
        if holdsThisPayload {
            held += 1; publish()
            await withCheckedContinuation { heldFetch = $0 }
            released += 1; publish()
            return isFile
                ? ChatMediaPayload(data: Data("Retired fixture payload must not publish".utf8), mimeType: "text/plain")
                : ChatMediaPayload(data: poison, mimeType: "image/png")
        }
        return isFile
            ? ChatMediaPayload(data: file, mimeType: "text/plain")
            : ChatMediaPayload(data: image, mimeType: "image/png")
    }
    func handle(_ method: String, params: [String: JSONValue]) -> JSONValue? {
        switch method {
        case "session.open":
            opens += 1; publish()
            let session = params["sessionId"]?.stringValue ?? "readonly-session"
            return .object(["session": try! JSONValue.encode(snapshot(session)), "syncToken": .string("fixture-sync-\(opens)"), "subscriptionToken": .string("fixture-subscription-\(opens)"), "completionRevision": .number(0)])
        case "session.sync": return .object(["synchronized": .bool(true)])
        case "session.close": return .object(["closed": .bool(true)])
        case "session.commands": return .object(["commands": .array([])])
        case "session.attention.read": return .object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)])
        case "session.list": return .object(["sessions": .array([])])
        default: return nil
        }
    }
    private func snapshot(_ sessionID: String) -> SessionSnapshot {
        var snapshot = SessionSnapshot(
            sessionId: sessionID, runtimeGeneration: "readonly-runtime", revision: 1, eventSequence: 1,
            phase: .idle, name: "Readonly previews", cwd: "/fixture", parentSessionId: nil, model: nil,
            thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
            stats: SessionStats(userMessages: 1, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 1,
                tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [], transcriptStart: 0,
            transcriptTotal: 1, streaming: nil, leafEntryId: "readonly-row", operation: nil, retry: nil, toolExecutions: [],
            extensionPresentation: ExtensionPresentationState(version: 3, hostEpoch: "readonly-host", revision: 1, capabilities: [], diagnostics: [],
                semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""), surfaces: [], pendingInteractions: []), diagnostics: [])
        let row: [String: Any] = ["id": "readonly-row", "presentationId": "readonly-row", "timestamp": "2026-01-01T00:00:00Z", "kind": "message", "role": "user", "content": [
            ["id": "readonly-image-part", "ordinal": 0, "type": "image", "blobId": "readonly-image", "mimeType": "image/png"],
            ["id": "readonly-file-part", "ordinal": 1, "type": "text", "text": "", "blobId": "readonly-file", "attachment": ["name": "readonly.txt", "mimeType": "text/plain", "size": file.count]]]]
        snapshot.transcript = try! JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: [row]))
        if scenario.contains("display") { snapshot.transcript = displayRows }
        snapshot.transcriptTotal = snapshot.transcript.count
        return snapshot
    }
}

private actor ReadonlyAttachmentSocket: GatewaySocketConnection {
    private let gateway: ReadonlyAttachmentGateway
    private var inbound: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    init(gateway: ReadonlyAttachmentGateway, replacement: Bool) {
        self.gateway = gateway
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":7,\"minProtocolVersion\":7,\"machineId\":\"\(replacement ? "readonly-replacement-machine" : "readonly-machine")\",\"machineName\":\"Fixture\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\"]}".utf8)]
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let request = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard let id = request["id"]?.stringValue, let method = request["method"]?.stringValue else { return }
        let result = await gateway.handle(method, params: request["params"]?.objectValue ?? [:])
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(result != nil)]
        if let result { response["result"] = result }
        else { response["error"] = .object(["code": .string("fixture_unsupported"), "message": .string("Optional fixture read"), "retryable": .bool(false)]) }
        deliver(try JSONEncoder.gateway.encode(JSONValue.object(response)))
    }
    func ping() async throws { if closed { throw CancellationError() } }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async { closed = true; receiver?.resume(throwing: CancellationError()); receiver = nil }
    private func deliver(_ data: Data) { if let receiver { self.receiver = nil; receiver.resume(returning: data) } else { inbound.append(data) } }
}

/// Bounded, HOSTED_TEST-only physical evidence. No selection/text/image bytes
/// are copied; a display boundary observes the actual mounted UIKit viewport.
private struct ReadonlyPreviewNativeRecorder: UIViewRepresentable {
    let update: (String) -> Void
    func makeUIView(context: Context) -> Recorder { Recorder(update: update) }
    func updateUIView(_ view: Recorder, context: Context) { view.update = update }
    final class Recorder: UIView {
        var update: (String) -> Void
        private var link: CADisplayLink?
        init(update: @escaping (String) -> Void) { self.update = update; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow(); link?.invalidate(); link = nil
            guard window != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(record)); link.add(to: .main, forMode: .common); self.link = link
        }
        @objc private func record() {
            guard let window else { return }
            let views = descendants(window)
            if views.compactMap({ $0 as? UITextView }).contains(where: { $0.text.hasPrefix("Retired fixture payload") }) { update("file retired:true"); return }
        if let text = views.compactMap({ $0 as? UITextView }).first(where: { !$0.isEditable && $0.text.hasPrefix("Readonly fixture row") }) {
                update("file native:\(ObjectIdentifier(text)) offset:\(Int(text.contentOffset.y)) selection:\(text.selectedRange.location):\(text.selectedRange.length)")
            } else if let image = views.compactMap({ $0 as? UIImageView }).first(where: { $0.accessibilityLabel == "Preview photo" || $0.accessibilityLabel == "Red above blue, with the close badge at top right." }), let scroll = ancestors(image).compactMap({ $0 as? UIScrollView }).first {
                update("image native:\(ObjectIdentifier(scroll)) zoom:\(String(format: "%.2f", scroll.zoomScale)) offset:\(Int(scroll.contentOffset.x)):\(Int(scroll.contentOffset.y)) height:\(image.image?.cgImage?.height ?? 0)")
            } else { update("none") }
        }
        private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        private func ancestors(_ view: UIView) -> [UIView] { guard let parent = view.superview else { return [] }; return [parent] + ancestors(parent) }
    }
}
#endif
