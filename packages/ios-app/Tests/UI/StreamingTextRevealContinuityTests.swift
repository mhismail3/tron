import SwiftUI
import Testing
import UIKit
@testable import TronMobile

/// Mounts the real `ChatStreamingInlineText` with every gate open, grows its
/// source on the Gateway's 150 ms progress cadence at about 40 words/s, and
/// samples rendered frames. Failure modes guarded here:
/// - the reveal falls behind the stream and a catch-up shows many words at
///   once with no fade (a jump in rendered ink);
/// - words stop fading in (no partially inked glyphs while streaming);
/// - the streaming view never converges to the full source.
/// A reference pane renders the same source settled (not streaming); both
/// panes share one layout, so glyph pixels compare one to one.
@MainActor
struct StreamingTextRevealContinuityTests {
    private static let paneSize = CGSize(width: 340, height: 360)
    private static let frameInterval: Duration = .milliseconds(150)
    private static let wordsPerFrame = 6
    private static let frameCount = 20
    private static let sampleInterval: Duration = .milliseconds(33)

    @Test("streaming text fades in continuously at 40 words/s on 150 ms frames")
    func streamingRevealIsContinuous() async throws {
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
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))

        let clock = ContinuousClock()
        let start = clock.now
        var nextFrame = start + Self.frameInterval
        var samples: [RevealSample] = [try Self.sample(window)]
        while admittedWords < words.count || clock.now < nextFrame {
            try await Task.sleep(for: Self.sampleInterval)
            if clock.now >= nextFrame, admittedWords < words.count {
                admittedWords += Self.wordsPerFrame
                host.rootView = fixture()
                nextFrame += Self.frameInterval
            }
            samples.append(try Self.sample(window))
        }
        let streamingSamples = samples
        let sampleMilliseconds = (clock.now - start) / Duration.milliseconds(1) / Double(samples.count - 1)
        try await Task.sleep(for: .milliseconds(1_200))
        let settled = try Self.sample(window)

        let inkPerWord = settled.referenceInk / Double(words.count)
        let jumps = zip(streamingSamples, streamingSamples.dropFirst()).map { ($1.streamingInk - $0.streamingInk) / inkPerWord }
        let largestJump = jumps.max() ?? 0
        let fadingShare = Double(streamingSamples.dropFirst().filter { $0.fadingPixels >= 8 }.count)
            / Double(streamingSamples.count - 1)
        print("""
            reveal continuity: samples=\(streamingSamples.count) \
            meanSampleMs=\(String(format: "%.1f", sampleMilliseconds)) largestJumpWords=\
            \(String(format: "%.2f", largestJump)) fadingShare=\(String(format: "%.2f", fadingShare)) \
            settledInkRatio=\(String(format: "%.4f", settled.streamingInk / settled.referenceInk))
            """)
        // Samples land about 60 ms apart, so steady pacing adds 2–5 words of
        // ink per sample; the pre-fix catch-up showed 18 or more at once.
        #expect(largestJump <= 8, "no sample may reveal more than a few words at once: \(largestJump) words")
        #expect(fadingShare >= 0.8, "words must be fading in most samples: \(fadingShare)")
        #expect(abs(settled.streamingInk / settled.referenceInk - 1) < 0.01, "the reveal converges to the source")
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
