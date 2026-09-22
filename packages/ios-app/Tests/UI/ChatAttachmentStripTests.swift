import SwiftUI
import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ChatAttachmentStripTests: XCTestCase {
    func testPhotoChipsStayCenteredAcrossEmptyBoundary() async throws {
        try await exercise(mimeType: "image/png", reduceMotion: false)
    }

    func testFileChipsStayCenteredAcrossEmptyBoundary() async throws {
        try await exercise(mimeType: "application/pdf", reduceMotion: false)
    }

    func testReducedMotionChipsFadeWithoutHorizontalTravel() async throws {
        try await exercise(mimeType: "image/png", reduceMotion: true)
    }

    private func exercise(mimeType: String, reduceMotion: Bool) async throws {
        let suite = "ChatAttachmentStripTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suite)
        let model = AppModel(
            client: GatewayClient(), profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot)
        )
        let state = AttachmentStripFixtureState()
        let appeared = expectation(description: "Attachment host appeared")
        let controller = AttachmentStripHostingController(rootView:
            AttachmentStripFixture(state: state, reduceMotion: reduceMotion)
                .environment(model)
                .tronPresentation()
        )
        controller.onDidAppear = { appeared.fulfill() }
        controller.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 180)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let appearance = await XCTWaiter.fulfillment(of: [appeared], timeout: 2)
        XCTAssertEqual(appearance, .completed)
        let first = try attachment(id: "first", mimeType: mimeType, color: .red)
        let second = try attachment(id: "second", mimeType: mimeType, color: .green)

        // Sample actual composited pixels, not SwiftUI's final layout frames:
        // scaling the full-width strip preserves layout but moves its paint.
        let firstInsertion = await capture(
            controller.view, state: state, expectedIDs: [first.id], transitionChannel: 0,
            expectsMotion: !reduceMotion
        ) { state.attachments = [first] }
        assertCentered(firstInsertion, channel: 0, center: 48, expectsMotion: !reduceMotion)
        let secondInsertion = await capture(
            controller.view, state: state, expectedIDs: [first.id, second.id], transitionChannel: 1,
            expectsMotion: !reduceMotion
        ) { state.attachments = [first, second] }
        assertCentered(secondInsertion, channel: 1, center: 120, expectsMotion: !reduceMotion)
        let secondRemoval = await capture(
            controller.view, state: state, expectedIDs: [first.id], transitionChannel: 1,
            expectsMotion: !reduceMotion
        ) { state.attachments = [first] }
        assertCentered(secondRemoval, channel: 1, center: 120, expectsMotion: !reduceMotion)
        let lastRemoval = await capture(
            controller.view, state: state, expectedIDs: [], transitionChannel: 0,
            expectsMotion: !reduceMotion
        ) { state.attachments = [] }
        assertCentered(lastRemoval, channel: 0, center: 48, expectsMotion: !reduceMotion)
        XCTAssertNil(lastRemoval.last?[0], "The last chip must disappear")
        XCTAssertEqual(state.stripHeight, 0, accuracy: 0.5, "No empty strip or spacing remains")

        // A new first chip reuses the same collection after removal.
        let reinsertion = await capture(
            controller.view, state: state, expectedIDs: [first.id], transitionChannel: 0,
            expectsMotion: !reduceMotion
        ) { state.attachments = [first] }
        assertCentered(reinsertion, channel: 0, center: 48, expectsMotion: !reduceMotion)
        await model.teardown()
    }

    private func assertCentered(
        _ samples: [[Int: CGRect]], channel: Int, center: CGFloat, expectsMotion: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let frames = samples.compactMap { $0[channel] }
        XCTAssertFalse(frames.isEmpty, "The requested chip must actually render", file: file, line: line)
        for frame in frames {
            XCTAssertEqual(frame.midX, center, accuracy: 2, "Chip paint must scale about its resting center", file: file, line: line)
        }
        if expectsMotion {
            XCTAssertTrue(frames.contains { $0.width > 12 && $0.width < 60 },
                          "Observe an intermediate scaled frame, not just the settled layout", file: file, line: line)
        }
    }

    private func attachment(id: String, mimeType: String, color: UIColor) throws -> PendingAttachment {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let data = try XCTUnwrap(image.pngData())
        let cgImage = try XCTUnwrap(image.cgImage)
        return PendingAttachment(
            id: id, name: id, mimeType: mimeType, size: data.count, previewData: data,
            preparedThumbnail: ComposerPreparedAttachmentThumbnail(
                encodedData: data, image: cgImage, decodedBytes: cgImage.bytesPerRow * cgImage.height
            )
        )
    }

    private func capture(
        _ view: UIView,
        state: AttachmentStripFixtureState,
        expectedIDs: [String],
        transitionChannel: Int,
        expectsMotion: Bool,
        mutation: () -> Void
    ) async -> [[Int: CGRect]] {
        let committed = expectation(description: "Attachment state committed")
        state.onAttachmentsCommitted = { ids in
            if ids == expectedIDs {
                state.onAttachmentsCommitted = nil
                committed.fulfill()
            }
        }
        defer { state.onAttachmentsCommitted = nil }

        let finished = expectation(description: "Rendered attachment animation settled")
        let recorder = AttachmentPaintRecorder(
            view: view,
            transitionChannel: transitionChannel,
            expectedChannels: Set(0..<expectedIDs.count),
            expectsMotion: expectsMotion,
            terminalState: { expectedIDs.isEmpty ? state.stripHeight == 0 : true }
        ) { finished.fulfill() }
        let ready = expectation(description: "Pre-mutation attachment frame rendered")
        recorder.onFirstFrame = { ready.fulfill() }
        recorder.start()
        defer { recorder.stop() }
        // UIKit appearance is not a SwiftUI render-commit acknowledgement.
        // Start from a painted baseline before requesting the next transition.
        let readiness = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(readiness, .completed)
        mutation()

        let commitResult = await XCTWaiter.fulfillment(of: [committed], timeout: 2)
        XCTAssertEqual(commitResult, .completed)
        recorder.stateCommitted = commitResult == .completed
        let completion = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(completion, .completed)
        return recorder.samples
    }
}

@MainActor
@Observable
private final class AttachmentStripFixtureState {
    var attachments: [PendingAttachment] = []
    var stripHeight: CGFloat = -1
    var onAttachmentsCommitted: (([String]) -> Void)?
}

private struct AttachmentStripFixture: View {
    let state: AttachmentStripFixtureState
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            ChatPendingAttachmentStrip(
                attachments: state.attachments, reduceMotion: reduceMotion,
                submissionTransitionActive: false,
                onRemove: { id in state.attachments.removeAll { $0.id == id } }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.stripHeight = $0 }
            .onChange(of: state.attachments.map(\.id)) { _, ids in
                state.onAttachmentsCommitted?(ids)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
    }
}

@MainActor
private final class AttachmentStripHostingController<Content: View>: UIHostingController<Content> {
    var onDidAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let callback = onDidAppear
        onDidAppear = nil
        callback?()
    }
}

@MainActor
private final class AttachmentPaintRecorder: NSObject {
    let view: UIView
    let transitionChannel: Int
    let expectedChannels: Set<Int>
    let expectsMotion: Bool
    let terminalState: () -> Bool
    let finished: () -> Void
    var samples: [[Int: CGRect]] = []
    var stateCommitted = false
    var onFirstFrame: (() -> Void)?
    private var stableFrames = 0
    private var observedIntermediateFrame = false
    private var displayLink: CADisplayLink?

    init(
        view: UIView,
        transitionChannel: Int,
        expectedChannels: Set<Int>,
        expectsMotion: Bool,
        terminalState: @escaping () -> Bool,
        finished: @escaping () -> Void
    ) {
        self.view = view
        self.transitionChannel = transitionChannel
        self.expectedChannels = expectedChannels
        self.expectsMotion = expectsMotion
        self.terminalState = terminalState
        self.finished = finished
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() { displayLink?.invalidate(); displayLink = nil }

    @objc private func frame(_ link: CADisplayLink) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        if let image = image.cgImage {
            let sample = Self.coloredBounds(image)
            samples.append(sample)
            let ready = onFirstFrame
            onFirstFrame = nil
            ready?()
            if let frame = sample[transitionChannel], frame.width > 12, frame.width < 60 {
                observedIntermediateFrame = true
            }
            // Presence alone can acknowledge an insertion mid-animation, or
            // acknowledge a removal while the outgoing chip is still painted.
            let settled = Set(sample.keys) == expectedChannels
                && sample.values.allSatisfy { $0.width >= 63 && $0.width <= 66 }
                && terminalState()
            if stateCommitted && settled && (!expectsMotion || observedIntermediateFrame) {
                stableFrames += 1
            } else {
                stableFrames = 0
            }
            if stableFrames >= 2 {
                stop()
                finished()
                return
            }
        }
    }

    private static func coloredBounds(_ image: CGImage) -> [Int: CGRect] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var result: [Int: CGRect] = [:]
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                for channel in 0...1 where pixels[index + channel] > 35
                    && Int(pixels[index + channel]) > Int(pixels[index + (1 - channel)]) * 3
                    && Int(pixels[index + channel]) > Int(pixels[index + 2]) * 3 {
                    let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                    result[channel] = result[channel].map { $0.union(pixel) } ?? pixel
                }
            }
        }
        // Near-zero opacity can leave only a few asymmetric quantized pixels
        // above the color threshold. A real chip is at least 32 points wide at
        // its smallest transform; sub-20-point speckles are not its bounds.
        return result.filter { $0.value.width >= 20 && $0.value.height >= 20 }
    }
}
