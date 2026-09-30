import SwiftUI
import Testing
import Synchronization
import UIKit
@testable import TronMobile
@testable import TronMobileCore

/// Mounts the real `ChatStreamingInlineText` with every gate open, grows its
/// source on the Gateway's 150 ms progress cadence at about 40 words/s, and
/// samples rendered frames. Failure modes guarded here:
/// - the reveal falls behind the stream and a catch-up shows many words at
///   once with no fade (a jump in rendered ink);
/// - words stop fading in (no partially inked glyphs while streaming);
/// - the streaming view never converges to the full source.
/// A reference pane renders the same source settled (not streaming); both
/// panes share one layout, so glyph pixels compare one to one.
///
/// The view's reveal clock is a manual clock, so every sample is rendered at
/// an exact reveal time after the reveal loop has run its tick for that time.
/// Sampling on the wall clock let a slow runner space samples further apart,
/// and each sample then legitimately showed more words.
@MainActor
struct StreamingTextRevealContinuityTests {
    private static let paneSize = CGSize(width: 340, height: 360)
    private static let frameInterval: Duration = .milliseconds(150)
    private static let wordsPerFrame = 6
    private static let frameCount = 20
    private static let sampleInterval: Duration = .milliseconds(33)
    /// Simulated time after the last frame for every fade to finish.
    private static let settleInterval: Duration = .milliseconds(1_200)

    @Test("streaming text fades in continuously at 40 words/s on 150 ms frames")
    func streamingRevealIsContinuous() async throws {
        try await withTestWatchdog(timeout: .seconds(30)) { @MainActor in
            try await Self.streamAndSample()
        }
    }

    private static func streamAndSample() async throws {
        let words = Self.words(count: Self.wordsPerFrame * (Self.frameCount + 1))
        let clock = RevealClock()
        var admittedWords = Self.wordsPerFrame
        func fixture() -> RevealFixture {
            RevealFixture(
                source: words.prefix(admittedWords).joined(separator: " "),
                paneSize: Self.paneSize,
                clock: clock.monotonicClock
            )
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: fixture())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: Self.paneSize.width, height: Self.paneSize.height * 2))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        // The mounted content is admitted at once by a task that starts after
        // the first commit; two display frames drain the main queue past it.
        for _ in 0..<2 { try await DisplayFrameScheduler.displayLink.nextFrame() }

        /// Advances reveal time one sample interval. The woken reveal loop is
        /// enqueued on the main actor before this task yields, so its whole
        /// tick (ending in its next sleep or its return) runs first.
        func advanceOneSample() async {
            clock.advance(by: Self.sampleInterval)
            await Task.yield()
        }
        /// A stream frame restarts the reveal task once SwiftUI commits the new
        /// source. The restarted loop always has new words to pace, so it is
        /// handled once it sleeps; only a catch-up (every word shown at once,
        /// which the render proves) returns instead.
        func restartHandled(sleepsBefore before: Int) async throws {
            while !(clock.sleepCount > before && clock.sleeperCount == 1) {
                if try Self.sample(window).isConverged { return }
                try await DisplayFrameScheduler.displayLink.nextFrame()
            }
        }

        var elapsed: Duration = .zero
        var nextFrame = Self.frameInterval
        var samples: [RevealSample] = [try Self.sample(window)]
        while admittedWords < words.count || elapsed < nextFrame {
            await advanceOneSample()
            elapsed += Self.sampleInterval
            if elapsed >= nextFrame, admittedWords < words.count {
                // The restart must neither grant nor withhold a word.
                let sleeps = clock.sleepCount
                admittedWords += Self.wordsPerFrame
                host.rootView = fixture()
                nextFrame += Self.frameInterval
                try await restartHandled(sleepsBefore: sleeps)
            }
            samples.append(try Self.sample(window))
        }
        let streamingSamples = samples

        // The loop sleeps until the last fade completes, then returns.
        var settleElapsed: Duration = .zero
        while clock.sleeperCount > 0, settleElapsed < Self.settleInterval {
            await advanceOneSample()
            settleElapsed += Self.sampleInterval
        }
        #expect(clock.sleeperCount == 0, "the reveal loop stops once every fade completes")
        let settled = try Self.sample(window)

        let inkPerWord = settled.referenceInk / Double(words.count)
        let jumps = zip(streamingSamples, streamingSamples.dropFirst()).map { ($1.streamingInk - $0.streamingInk) / inkPerWord }
        let largestJump = jumps.max() ?? 0
        let fadingShare = Double(streamingSamples.dropFirst().filter { $0.fadingPixels >= 8 }.count)
            / Double(streamingSamples.count - 1)
        print("""
            reveal continuity: samples=\(streamingSamples.count) \
            sampleMs=\(Self.sampleInterval) largestJumpWords=\
            \(String(format: "%.2f", largestJump)) fadingShare=\(String(format: "%.2f", fadingShare)) \
            settledInkRatio=\(String(format: "%.4f", settled.streamingInk / settled.referenceInk))
            """)
        // Samples land 33 ms apart in reveal time, so steady pacing adds one or
        // two words of ink per sample; the pre-fix catch-up showed 18 or more
        // at once.
        #expect(largestJump <= 8, "no sample may reveal more than a few words at once: \(largestJump) words")
        #expect(fadingShare >= 0.8, "words must be fading in most samples: \(fadingShare)")
        #expect(settled.isConverged, "the reveal converges to the source")
    }

    private static func words(count: Int) -> [String] {
        let vocabulary = ["stream", "reveal", "a", "gateway", "of", "thinking", "continuous", "to", "response",
                          "fade", "model", "the", "tokens", "arrive", "smoothly", "in"]
        return (0..<count).map { vocabulary[($0 * 7 + $0 / 5) % vocabulary.count] }
    }

    /// Ink is summed darkness (255 − luma) over a pane. A fading pixel is a
    /// reference glyph core whose streaming pixel is clearly partially inked.
    private static func sample(_ window: UIWindow) throws -> RevealSample {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let paneRows = height / 2
        var result = RevealSample()
        for row in 0..<paneRows {
            for column in 0..<width {
                let streaming = Double(255 - pixels[row * width + column])
                let reference = Double(255 - pixels[(row + paneRows) * width + column])
                result.streamingInk += streaming
                result.referenceInk += reference
                if reference > 128, streaming > 0.15 * reference, streaming < 0.85 * reference {
                    result.fadingPixels += 1
                }
            }
        }
        return result
    }
}

private struct RevealSample {
    var streamingInk = 0.0
    var referenceInk = 0.0
    var fadingPixels = 0

    /// Every admitted word renders at full ink.
    var isConverged: Bool { abs(streamingInk / referenceInk - 1) < 0.01 }
}

/// The streaming pane over a settled reference pane of the same source.
private struct RevealFixture: View {
    let source: String
    let paneSize: CGSize
    let clock: MonotonicClock

    var body: some View {
        VStack(spacing: 0) {
            pane(streaming: true)
            pane(streaming: false)
        }
        .background(Color.white)
        .environment(\.scenePhase, .active)
        .environment(\.chatStreamingRevealClock, clock)
    }

    private func pane(streaming: Bool) -> some View {
        ChatStreamingInlineText(
            inline: MarkdownPresentation.Inline(source: source),
            identity: "reveal-continuity",
            baseColor: .black,
            streaming: streaming
        )
        .font(.system(size: 13))
        .foregroundStyle(.black)
        .frame(width: paneSize.width, height: paneSize.height, alignment: .topLeading)
        .clipped()
    }
}

/// The reveal loop's clock. Its sleeps are main-actor isolated, so resuming
/// one from the test enqueues the woken loop on the main actor ahead of the
/// test's next yield; `sleepCount` and `sleeperCount` show whether the loop is
/// paced (asleep) or has stopped.
@MainActor
private final class RevealClock {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let origin = ContinuousClock.now
    private let offset = Mutex<Duration>(.zero)
    private var sleepers: [Sleeper] = []
    private var nextID = 0
    private(set) var sleepCount = 0

    var sleeperCount: Int { sleepers.count }

    nonisolated var monotonicClock: MonotonicClock {
        MonotonicClock(
            now: { self.now() },
            sleep: { duration in try await self.sleep(for: duration) },
            gridOrigin: origin
        )
    }

    nonisolated private func now() -> ContinuousClock.Instant {
        origin + offset.withLock { $0 }
    }

    func advance(by duration: Duration) {
        let now = offset.withLock { value -> Duration in
            value += duration
            return value
        }
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func sleep(for duration: Duration) async throws {
        let id = nextID
        nextID += 1
        sleepCount += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append(Sleeper(
                        id: id, deadline: offset.withLock { $0 } + duration, continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
