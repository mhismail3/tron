import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import TronMobileCore
@testable import TronMobile

@Suite("Display video playback", .serialized)
@MainActor
struct DisplayVideoPlaybackTests {
    @Test("HTTP-staged MP4 reaches player readiness and advances playback")
    func stagedVideoPlayback() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).mp4")
            defer { try? FileManager.default.removeItem(at: source) }
            try await Self.writeVideo(to: source)
            let bytes = try Data(contentsOf: source)
            let server = try await LoopbackHTTPServer.start { _ in
                .init(headers: [("Content-Type", "video/mp4")], body: bytes)
            }
            defer { server.stop() }
            let profile = GatewayProfile(
                id: "video-machine", label: "Video", host: "127.0.0.1", port: Int(server.port),
                machineId: "video-machine", deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":\#(TronGatewayProtocolContract.protocolVersion),"minProtocolVersion":\#(TronGatewayProtocolContract.minimumProtocolVersion),"machineId":"video-machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","display-artifacts.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "test-token")
            let staged: URL
            do {
                staged = try await client.displayArtifactFile(
                    id: "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b", sessionID: "session", profileID: profile.id,
                    maximumBytes: bytes.count, expectedBytes: Int64(bytes.count)
                )
            } catch {
                await client.close()
                throw error
            }
            await client.close()
            defer { BoundedHTTPFileStaging.shared.discard(staged) }
            #expect(try Data(contentsOf: staged) == bytes)
            let playback = DisplayVideoPlayback()
            await playback.prepare(mimeType: "video/mp4") { staged }
            defer { playback.stop() }
            let player = try #require(playback.player)
            let item = try #require(player.currentItem)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while item.status == .unknown && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            print("DISPLAY_VIDEO_PROBE status=\(item.status.rawValue) error=\(String(describing: item.error)) stagedExtension=\(staged.pathExtension)")
            try #require(item.status == .readyToPlay)
            player.play()
            while player.currentTime().seconds < 0.2 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(player.currentTime().seconds >= 0.2)
            let generator = AVAssetImageGenerator(asset: item.asset)
            let image = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
            #expect(image.width == 64 && image.height == 64)
        }
    }

    @Test("malformed staged media fails visibly, retires its file and records safe player diagnostics")
    func malformedMedia() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) { @MainActor in
            let file = try BoundedHTTPFileStaging.shared.reserveDestination(incomingBytes: 7)
            try Data("invalid".utf8).write(to: file)
            defer { BoundedHTTPFileStaging.shared.discard(file) }
            let playback = DisplayVideoPlayback()
            await playback.prepare(mimeType: "video/mp4") { file }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !playback.failed && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(playback.failed)
            #expect(playback.player == nil)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            var failure: AppLogRecord?
            while failure == nil && ContinuousClock.now < deadline {
                failure = await AppLog.shared.snapshot().last {
                    $0.event == "display.media" && $0.requestID == playback.requestID && $0.outcome == "failure"
                }
                if failure == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            let record = try #require(failure)
            #expect(record.message.contains("stage=player"))
            #expect(record.message.contains("domain=AVFoundationErrorDomain"))
            #expect(!record.message.contains(file.path))
            playback.stop()
        }
    }

    @Test("retired and superseded loads cannot publish players, failures or retain files")
    func stalePreparation() async throws {
        let playback = DisplayVideoPlayback()
        let first = try BoundedHTTPFileStaging.shared.reserveDestination(incomingBytes: 1)
        let second = try BoundedHTTPFileStaging.shared.reserveDestination(incomingBytes: 1)
        try Data([0]).write(to: first)
        try Data([1]).write(to: second)
        defer {
            playback.stop()
            BoundedHTTPFileStaging.shared.discard(first)
            BoundedHTTPFileStaging.shared.discard(second)
        }
        let gate = DisplayVideoFileGate()
        let old = Task { await playback.prepare(mimeType: "video/mp4") { await gate.wait(); return first } }
        await gate.started()
        // A newer request fails before the old uncancellable download returns.
        await playback.prepare(mimeType: "video/mp4") { throw URLError(.notConnectedToInternet) }
        #expect(playback.failed)
        await gate.release()
        await old.value
        #expect(playback.failed)
        #expect(playback.player == nil)
        #expect(!FileManager.default.fileExists(atPath: first.path))

        let retiredGate = DisplayVideoFileGate()
        let retired = Task { await playback.prepare(mimeType: "video/mp4") { await retiredGate.wait(); return second } }
        await retiredGate.started()
        playback.stop()
        await retiredGate.release()
        await retired.value
        #expect(playback.player == nil)
        #expect(!playback.failed)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test("cancelled download and stale download errors do not publish failures")
    func cancelledAndStaleFailures() async {
        let playback = DisplayVideoPlayback()
        let gate = DisplayVideoFileGate()
        let old = Task { await playback.prepare(mimeType: "video/mp4") { await gate.wait(); throw URLError(.badServerResponse) } }
        await gate.started()
        playback.stop()
        await gate.release()
        await old.value
        #expect(!playback.failed)
        await playback.prepare(mimeType: "video/mp4") { throw CancellationError() }
        #expect(!playback.failed)
        #expect(playback.player == nil)
    }

    private static func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixel = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 128, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            try #require(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}

private actor DisplayVideoFileGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    func wait() async {
        hasStarted = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func started() async {
        if hasStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
