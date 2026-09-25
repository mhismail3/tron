import SwiftUI
import XCTest
@testable import TronMobile

/// Small visual checkpoint for the real anchored overlay, not a second drawing
/// of the slider. Device gesture/haptic feel remains a hands-on checkpoint.
@MainActor
final class ContextWindowSliderLayoutTests: XCTestCase {

    func testMorphContainsContentAtIntermediateFrames() async throws {
        let source = CGRect(x: 230, y: 166, width: 72, height: 28)
        let target = CGRect(x: 18, y: 95, width: 284, height: 170)
        // Opening and closing use the same fraction-to-geometry mapping. These
        // are actual native render samples, not a timing-sensitive animation test.
        for (fraction, reduceMotion) in [(CGFloat(0.4), false), (0.6, false), (0.8, false), (0.95, false), (0.6, true)] {
            let image = try await capture(
                ConfigurationSliderSurface(source: source, target: target, fraction: fraction, reduceMotion: reduceMotion, accent: .clear) {
                    // Include the native scroll layer used by both editors;
                    // its composited knob must obey the same morph clip.
                    ScrollView {
                        Color(red: 1, green: 0, blue: 1)
                            .frame(width: target.width, height: target.height)
                            .overlay {
                                Circle().fill(.white.opacity(0.1))
                                    .glassEffect(.regular, in: .circle)
                                    .frame(width: 38, height: 38)
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } label: { EmptyView() }
                    .background(.white)
                    .environment(\.colorScheme, .light),
                size: CGSize(width: 320, height: 360)
            )
            let geometry = reduceMotion ? 1 : fraction
            let frame = CGRect(
                x: source.minX + (target.minX - source.minX) * geometry,
                y: source.minY + (target.minY - source.minY) * geometry,
                width: source.width + (target.width - source.width) * geometry,
                height: source.height + (target.height - source.height) * geometry
            )
            let radius = 14 + (32 - 14) * geometry
            let allowed = CGPath(roundedRect: frame.insetBy(dx: -2, dy: -2), cornerWidth: radius + 2, cornerHeight: radius + 2, transform: nil)
            let bitmap = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: bitmap.width, height: bitmap.height,
                    bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
            }
            var inside = 0
            var outside = 0
            var paintedLeft = CGFloat.infinity
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width {
                    let offset = (y * bitmap.width + x) * 4
                    if Int(pixels[offset]) > Int(pixels[offset + 1]) + 20,
                       Int(pixels[offset + 2]) > Int(pixels[offset + 1]) + 20 {
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / image.scale, y: (CGFloat(y) + 0.5) / image.scale)
                        paintedLeft = min(paintedLeft, point.x)
                        if allowed.contains(point) { inside += 1 } else { outside += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(inside, 100, "The containment oracle must see real content at \(fraction)")
            XCTAssertEqual(outside, 0, "Content escaped the animated glass boundary at \(fraction)")
            if reduceMotion {
                XCTAssertLessThan(paintedLeft, target.minX + 5, "Reduce Motion must fade at destination size, never interpolate its geometry")
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "configuration-slider-morph-\(fraction)-reduce-motion-\(reduceMotion)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func capture<Content: View>(_ content: Content, size: CGSize, settling: Duration? = nil) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Slider host appeared")
        let host = SliderHostingController(rootView: content)
        host.onAppear = { appeared.fulfill() }
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [appeared], timeout: 2)
        // Only the visual preview waits for its known opening spring; static
        // intermediate-frame assertions join UIKit appearance directly.
        if let settling { try await Task.sleep(for: settling) }
        host.view.layoutIfNeeded()
        return UIGraphicsImageRenderer(size: size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

@MainActor
private final class SliderHostingController<Content: View>: UIHostingController<Content> {
    var onAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let completion = onAppear
        onAppear = nil
        completion?()
    }
}
