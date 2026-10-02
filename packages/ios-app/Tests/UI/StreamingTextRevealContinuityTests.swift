import SwiftUI
import Testing
import UIKit
@testable import TronMobile
@testable import TronMobileCore

/// Failure modes: pacing catches up ordinary progress in a burst, fades are
/// bypassed, or mounted text never converges to its authoritative source.
/// Virtual-time policy coverage owns throughput. Native samples own rendered
/// ink and convergence, not a promise that a loaded host catches every fade.
@MainActor
struct StreamingTextRevealContinuityTests {
    private static let paneSize = CGSize(width: 340, height: 360)
    private static let wordsPerFrame = 6
    private static let frameCount = 20

    @Test("streaming text fades continuously and the mounted source converges")
    func streamingRevealIsContinuous() async throws {
        let arrivals = RevealCadence.gateway150.arrivals(wordsPerSecond: 40, durationMilliseconds: 3_000)
        for tickDelay in [0.0, 90.0] {
            let schedule = RevealSimulation.current(arrivals: arrivals, tickDelay: tickDelay)
            #expect(schedule.poppedWords == 0, "ordinary progress must not skip fades")
            #expect(schedule.starts.count == arrivals.count)
            let samples = stride(from: 0.0, through: 4_200.0, by: 33.0).map { now in
                schedule.starts.reduce(0.0) {
                    $0 + ChatStreamingTextRevealPolicy.opacity(elapsedMilliseconds: Int(now - $1))
                }
            }
            let jumps = zip(samples, samples.dropFirst()).map { $1 - $0 }
            #expect((jumps.max() ?? 0) <= 8, "paced opacity cannot publish a burst")
            #expect(samples.last == Double(arrivals.count), "every scheduled fade converges")
        }
        // The existing pre-fix scheduler is a behavioral negative control,
        // not an expected-value copy of the production policy.
        #expect(RevealSimulation.restartDriven(arrivals: arrivals).poppedWords > 0)

        let words = Self.words(count: Self.wordsPerFrame * (Self.frameCount + 1))
        var admittedWords = Self.wordsPerFrame
        func fixture() -> RevealFixture {
            RevealFixture(source: words.prefix(admittedWords).joined(separator: " "), paneSize: Self.paneSize)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: fixture())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: Self.paneSize.width, height: Self.paneSize.height * 2))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        var measurements: [[String: Double]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys]) {
                Attachment.record(data, named: "mounted-reveal-ink.json")
            }
        }
        func settleInk(referenceAfter priorReference: Double = 0) async throws {
            var previousInk = 0.0
            for frame in 0..<120 {
                try await DisplayFrameScheduler.displayLink.nextFrame()
                let sample = try Self.sample(window)
                if sample.referenceInk <= priorReference { continue }
                #expect(sample.streamingInk <= sample.referenceInk * 1.01, "the render cannot duplicate source glyphs")
                #expect(sample.streamingInk + sample.referenceInk * 0.01 >= previousInk, "revealed glyphs cannot disappear within one source revision")
                previousInk = sample.streamingInk
                measurements.append(["words": Double(admittedWords), "frame": Double(frame),
                                     "inkRatio": sample.streamingInk / sample.referenceInk,
                                     "fadingPixels": Double(sample.fadingPixels)])
                if sample.referenceInk > 0, sample.isConverged { return }
            }
            try #require(Bool(false), "Mounted reveal did not converge within 120 display boundaries")
        }
        try await settleInk()
        for _ in 0..<Self.frameCount {
            let priorReference = try Self.sample(window).referenceInk
            admittedWords += Self.wordsPerFrame
            host.rootView = fixture()
            try await settleInk(referenceAfter: priorReference)
        }
        let settled = try Self.sample(window)
        #expect(settled.isConverged)
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

    /// Every admitted word renders at full ink, within 1% of the reference.
    var isConverged: Bool { abs(streamingInk / referenceInk - 1) < 0.01 }
}

/// The streaming pane over a settled reference pane of the same source.
private struct RevealFixture: View {
    let source: String
    let paneSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            pane(streaming: true)
            pane(streaming: false)
        }
        .background(Color.white)
        .environment(\.scenePhase, .active)
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
