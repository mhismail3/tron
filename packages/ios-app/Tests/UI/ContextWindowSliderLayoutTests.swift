import SwiftUI
import XCTest
@testable import TronMobile

/// Small visual checkpoint for the real anchored overlay, not a second drawing
/// of the slider. Device gesture/haptic feel remains a hands-on checkpoint.
@MainActor
final class ContextWindowSliderLayoutTests: XCTestCase {
    func testExpandedGlassLayouts() async throws {
        for (name, scheme, typeSize, width) in [("phone", ColorScheme.light, DynamicTypeSize.large, CGFloat(440)),
                                               ("light", .light, .large, 320), ("dark", .dark, .large, 320),
                                               ("large-text", .light, .accessibility3, 320),
                                               // A default at the maximum must keep its label on the endpoint row.
                                               ("default-at-max", .dark, .large, 393)] {
            let image = try await capture(
                SliderFixture(defaultValue: name == "default-at-max" ? 1_000_000 : 272_000,
                              maximum: name == "default-at-max" ? 1_000_000 : 1_050_000)
                    .tronPresentation()
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, typeSize),
                size: CGSize(width: width, height: 540), settling: .milliseconds(600)
            )
            XCTAssertEqual(image.size.width, width)
            let attachment = XCTAttachment(image: image)
            attachment.name = "context-window-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testBackdropSoftensNearbyDetailButLeavesDistantContentSharp() async throws {
        let frame = CGRect(x: 60, y: 160, width: 320, height: 120)
        let image = try await capture(
            ZStack {
                Canvas { context, size in
                    for x in stride(from: CGFloat.zero, to: size.width, by: 4) {
                        context.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(.black))
                    }
                }
                .background(.white)
                ConfigurationSliderSurface(source: frame, target: frame, fraction: 1, reduceMotion: false, accent: .tronPurple) {
                    EmptyView()
                } label: { EmptyView() }
            }
            .environment(\.colorScheme, .light),
            size: CGSize(width: 440, height: 440)
        )
        let bitmap = try XCTUnwrap(image.cgImage)
        func contrast(at y: CGFloat) throws -> Double {
            let band = try XCTUnwrap(bitmap.cropping(to: CGRect(x: 0, y: y * image.scale, width: CGFloat(bitmap.width), height: image.scale)))
            var pixels = [UInt8](repeating: 0, count: band.width * band.height * 4)
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: band.width, height: band.height,
                    bitsPerComponent: 8, bytesPerRow: band.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(band, in: CGRect(x: 0, y: 0, width: band.width, height: band.height))
            }
            let differences = stride(from: 112, to: 328, by: 4).map { x in
                let dark = Int(CGFloat(x + 1) * image.scale) * 4
                let light = Int(CGFloat(x + 3) * image.scale) * 4
                return Double(Int(pixels[light]) - Int(pixels[dark])) / 255
            }
            return differences.reduce(0, +) / Double(differences.count)
        }
        let far = try contrast(at: 30)
        let near = try contrast(at: 140) // 20pt outside the glass, not its own material.
        let center = try contrast(at: 220)
        XCTAssertGreaterThan(far, 0.9, "Distant rows must remain sharp")
        XCTAssertLessThan(near, far * 0.75, "The halo must visibly soften detail outside the panel, not merely exist as a layer")
        XCTAssertLessThan(center, far * 0.1, "The panel backdrop must actually filter fine detail, not leave sharp stripes behind tinted glass")
        let attachment = XCTAttachment(image: image)
        attachment.name = "context-window-local-blur"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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

private struct SliderFixture: View {
    @State private var presentation = ConfigurationSliderPresentation()
    @State private var owner = UUID()
    var defaultValue = 272_000
    var maximum = 1_050_000

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    TronSettingsRow(icon: "brain", title: "Thinking", accent: .tronPurple) {
                        TronInlineActionLabel("Extra High", accent: .tronPurple)
                    }
                    TronSettingsDivider(accent: .tronPurple)
                    TronSettingsRow(icon: "gauge.with.dots.needle.50percent", title: "Context Window", accent: .tronPurple) {
                        TronInlineActionLabel("272,000", accent: .tronPurple)
                            .opacity(0)
                            .anchorPreference(key: ConfigurationSliderPreference.self, value: .bounds) { anchor in
                                guard let session = presentation.session else { return nil }
                                return ConfigurationSliderRequest(
                                    session: session, anchor: anchor, sourceVerticalInset: 8, accent: .tronPurple,
                                    editor: .contextWindow(ContextWindowSliderRequest(
                                        scale: ContextWindowSliderScale(
                                            limits: ContextWindowLimits(minimum: 37_408, maximum: maximum, default: defaultValue, longContextThreshold: nil),
                                            defaultValue: defaultValue
                                        ), value: defaultValue, selection: nil, title: defaultValue.formatted(),
                                        resetLabel: "Use configured default", detail: "Supported model bounds.", finish: { _ in }
                                    ))
                                )
                            }
                    }
                    TronSettingsDivider(accent: .tronPurple)
                    TronSettingsRow(icon: "rectangle.compress.vertical", title: "Automatic Compaction", subtitle: "Enabled", accent: .tronPurple)
                }
                .controlSize(.small)
                .tronGlassSurface(accent: .tronPurple)
                .padding(18)
                .padding(.top, 60)
            }
            .navigationTitle("Manage Session")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tronConfigurationSliderHost(presentation)
        .onAppear { presentation.open(owner: owner) }
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
