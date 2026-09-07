import SwiftUI
import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SessionSummaryLayoutTests: XCTestCase {
    func testUsageSummaryKeepsOneCompactHeaderAndStatsBand() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_810).openingTail(targetEncodedBytes: 4_096)
        snapshot.contextUsage = ContextUsage(tokens: 162_000, contextWindow: 272_000, percent: 60)
        snapshot.stats = SessionStats(
            userMessages: 10, assistantMessages: 10, toolCalls: 30, toolResults: 30, totalMessages: 50,
            tokens: .init(input: 164_000, output: 23_000, cacheRead: 7_900_000, cacheWrite: 0, total: 8_087_000),
            latestCacheHitRate: 99.7, cost: 10.70
        )
        for scheme: ColorScheme in [.light, .dark] {
            let size = try await render(
                SessionContextUsageCard(snapshot: SessionContextPresentation(snapshot))
                    .environment(\.colorScheme, scheme),
                width: 404,
                name: "usage-summary-\(scheme)",
                inspectImage: { image in self.assertStatisticsUseSecondaryText(image, scheme: scheme) }
            )
            XCTAssertEqual(size.width, 404, accuracy: 1)
            // Header + progress separator + metric band, including card padding.
            // The former extra context/compaction row and divider exceed this.
            XCTAssertLessThan(size.height, 130)
            XCTAssertGreaterThan(size.height, 90)
        }
    }

    func testExtensionResourcePreviewDoesNotBecomeATallSourceContainer() async throws {
        let text = String(repeating: "Read the selected resource before continuing. ", count: 1_500)
        let preview = ComposerResourceContentPresentation.preview(text, source: .extension, sourceTruncated: true)
        let size = try await render(
            ComposerResourceContentBody(preview: preview, source: .extension)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tronScrollSurface(accent: .tronIndigo, cornerRadius: 16, tintOpacity: 0.06),
            width: 320, name: "resource-preview-extension"
        )
        XCTAssertEqual(size.width, 320, accuracy: 1)
        XCTAssertLessThan(size.height, 350, "Extension previews should not render the transport's 96-KiB body")
    }

    func testLeftAlignedSettingValuesUseTheSameReadingFontAsDescriptions() async throws {
        let text = String(repeating: "Minimum eligible interval: fifteen minutes. ", count: 5)
        for width: CGFloat in [260, 404] {
            let description = try await render(
                TronValueRow(icon: "timer", title: "Interval", detail: text) {
                    Text("Change").font(TronTypography.secondaryDescription)
                }, width: width
            )
            let value = try await render(
                TronValueRow(icon: "timer", title: "Interval", value: text) {
                    Text("Change").font(TronTypography.secondaryDescription)
                }, width: width, name: "left-aligned-value-\(Int(width))"
            )
            XCTAssertEqual(value.height, description.height, accuracy: 0.5,
                "Moving a value under its title must use the reading family, not a monospace-only subtitle role")
            XCTAssertEqual(value.width, description.width, accuracy: 0.5)
        }
    }

    func testBranchNameStaysBelowTitleAndStatusFitsTheTrailingValueSlot() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            for (name, presentation): (String, SessionWorkspaceRowPresentation) in [
                ("clean", .loaded(branch: "main", dirty: false, changeCount: 0)),
                ("dirty", .loaded(branch: "feature/a-deliberately-long-branch-name", dirty: true, changeCount: 12)),
                ("detached", .loaded(branch: "Detached · aabbccdd", dirty: false, changeCount: 0)),
            ] {
                let size = try await render(
                    SessionWorkspaceSummaryRow(presentation: presentation, accent: .tronBlue)
                        .tronGlassSurface(accent: .tronCyan)
                        .environment(\.tronSettingsSecondaryTextSizeAdjustment, SessionSummaryTypography.metadataSizeAdjustment)
                        .environment(\.colorScheme, scheme),
                    width: 320, name: "branch-summary-\(name)-\(scheme)"
                )
                XCTAssertEqual(size.width, 320, accuracy: 1)
                XCTAssertLessThan(size.height, 85, "Long branch names must not crowd out the working-tree status")
            }
        }
    }

    private func modelSummary(name: String) -> some View {
        let selected = ModelSummary(
            provider: "test-provider", id: "test-model",
            name: name,
            reasoning: true, input: ["text"], contextWindow: 272_000,
            maxTokens: 8_192, available: true
        )
        return SessionModelSummaryCard(
            selection: .constant(selected.ref), catalog: [selected], automaticCompactionEnabled: true
        ) {
            TronThinkingSelectionRow(selection: .constant("xhigh"), levels: ["off", "high", "xhigh"], accent: .tronEmerald)
            TronSettingsDivider(accent: .tronEmerald)
            ContextWindowSelectionRow(
                selection: .constant(nil),
                limits: ContextWindowLimits(minimum: 1_000, maximum: 1_048_576, default: 272_000, longContextThreshold: nil),
                inheritedValue: 272_000, effectiveValue: 272_000,
                resetLabel: "Use configured default", source: "model", accent: .tronEmerald
            )
        } compactAction: {
            Button {} label: {
                TronInlineActionLabel("Compact Now", icon: "rectangle.compress.vertical")
            }
            .buttonStyle(.plain)
        }
        .environment(\.tronSettingsSecondaryTextSizeAdjustment, SessionSummaryTypography.metadataSizeAdjustment)
    }

    func testModelActionsDoNotAddHeightToStandardRows() async throws {
        let adjustment = SessionSummaryTypography.metadataSizeAdjustment
        let thinkingReference = try await render(
            TronSettingsRow(icon: "brain", title: "Thinking"), width: 404
        )
        let thinking = try await render(
            TronThinkingSelectionRow(selection: .constant("xhigh"), levels: ["off", "xhigh"])
                .controlSize(.small), width: 404
        )
        XCTAssertEqual(thinking.height, thinkingReference.height, accuracy: 0.5)

        let reference = try await render(
            TronSettingsRow(icon: "rectangle.compress.vertical", title: "Automatic Compaction",
                            subtitle: "Enabled")
                .environment(\.tronSettingsSecondaryTextSizeAdjustment, adjustment), width: 404
        )
        let compaction = try await render(
            TronSettingsRow(icon: "rectangle.compress.vertical", title: "Automatic Compaction",
                            subtitle: "Enabled") {
                Button {} label: { TronInlineActionLabel("Compact Now", icon: "rectangle.compress.vertical") }
                    .buttonStyle(.plain)
            }
            .controlSize(.small)
            .environment(\.tronSettingsSecondaryTextSizeAdjustment, adjustment), width: 404
        )
        XCTAssertEqual(compaction.height, reference.height, accuracy: 0.5)
        let regular = try await render(
            TronSettingsRow(icon: "brain", title: "Thinking") {
                TronInlineMenu("Change") { Button("Extra High") {} }
            }.controlSize(.regular), width: 404
        )
        // This correction is local to compact targets, not global Settings spacing.
        XCTAssertEqual(regular.height, 60, accuracy: 0.5)
    }

    func testModelSummaryDisplaysValueActionsInLightAndDark() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            let size = try await render(
                modelSummary(name: "Example Model").environment(\.colorScheme, scheme),
                width: 404, name: "model-summary-values-\(scheme)"
            )
            XCTAssertEqual(size.width, 404, accuracy: 1)
            // Compact actions share the standard rows' insets rather than
            // adding their 44-point targets on top of another 24-point padding.
            XCTAssertLessThan(size.height, 250)
        }
    }

    func testModelSummaryWrapsLongNamesAndAccessibilityTextWithoutWidening() async throws {
        let content = modelSummary(name: "A Model With A Deliberately Long Display Name")
        let normal = try await render(content, width: 320, name: "model-summary-long-name")
        let accessible = try await render(
            content.environment(\.dynamicTypeSize, .accessibility3),
            width: 320,
            name: "model-summary-accessibility"
        )
        XCTAssertEqual(normal.width, 320, accuracy: 1)
        XCTAssertEqual(accessible.width, 320, accuracy: 1)
        XCTAssertGreaterThan(accessible.height, normal.height)
        XCTAssertLessThan(normal.height, 400)
        // Accessibility must stack actions below full-width labels instead of
        // forcing a long model name into the narrow space beside its button.
        XCTAssertLessThan(accessible.height, 900)
    }

    func testSmallActionKeepsFullTouchHeightAndMetadataAdjustmentIsLocal() async throws {
        let small = try await render(TronInlineActionLabel("Change").controlSize(.small), width: 90)
        let regular = try await render(TronInlineActionLabel("Change"), width: 90)
        XCTAssertEqual(small.height, 44, accuracy: 0.5)
        XCTAssertEqual(regular.height, 36, accuracy: 0.5)
        XCTAssertEqual(EnvironmentValues().tronSettingsSecondaryTextSizeAdjustment, 0)
        XCTAssertEqual(SessionSummaryTypography.metadataSizeAdjustment, 0.5)
        XCTAssertEqual(SessionSummaryTypography.detail, TronTypography.sans(size: TronTypography.sizeSecondary + 0.5))
        XCTAssertEqual(SessionSummaryTypography.usageValue, TronTypography.code(size: TronTypography.sizeSecondary + 0.5))
        XCTAssertEqual(SessionSummaryTypography.metricLabel, TronTypography.sans(size: TronTypography.sizeSecondary + 0.5))
        // Serif captions and semibold monospace values share the same point scale.
        XCTAssertEqual(SessionSummaryTypography.metric, TronTypography.code(size: TronTypography.sizeSecondary + 0.5, weight: .semibold))
        XCTAssertEqual(SessionSummaryTypography.headline, TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
    }

    private func assertStatisticsUseSecondaryText(_ image: UIImage, scheme: ColorScheme) {
        guard let imageData = image.cgImage,
              let band = imageData.cropping(to: CGRect(
                x: 0, y: imageData.height - Int(56 * image.scale),
                width: imageData.width, height: Int(42 * image.scale)
              )) else { return XCTFail("Statistics band must be rendered") }
        var pixels = [UInt8](repeating: 0, count: band.width * band.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: band.width, height: band.height, bitsPerComponent: 8,
                bytesPerRow: band.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(band, in: CGRect(x: 0, y: 0, width: band.width, height: band.height))
        }
        let traits = UITraitCollection(userInterfaceStyle: scheme == .light ? .light : .dark)
        func matches(_ color: Color) -> Int {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            var count = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let redDifference = abs(CGFloat(pixels[index]) / 255 - red)
                let greenDifference = abs(CGFloat(pixels[index + 1]) / 255 - green)
                let blueDifference = abs(CGFloat(pixels[index + 2]) / 255 - blue)
                if redDifference < 0.025, greenDifference < 0.025, blueDifference < 0.025, pixels[index + 3] > 230 {
                    count += 1
                }
            }
            return count
        }
        XCTAssertGreaterThan(matches(.tronTextSecondary), 30, "Stats must contain the existing gray label color")
        XCTAssertEqual(matches(.tronTextPrimary), 0, "Stat values must not retain black/primary paint")
    }

    private func render<Content: View>(
        _ content: Content, width: CGFloat, name: String? = nil,
        inspectImage: ((UIImage) -> Void)? = nil
    ) async throws -> CGSize {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Summary host completed appearance")
        let controller = SummaryLayoutHostingController(rootView: content.tronPresentation())
        controller.onDidAppear = { appeared.fulfill() }
        // Measure the card/action, not a whole screen with status/home insets.
        controller.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1_200)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // Join UIKit's actual appearance, not an arbitrary delay or queue turn.
        // Removing a host before this callback leaves unbalanced transitions.
        let appearance = await XCTWaiter.fulfillment(of: [appeared], timeout: 2)
        XCTAssertEqual(appearance, .completed)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 2_000))
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        if name != nil || inspectImage != nil {
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            inspectImage?(image)
            if let name {
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        window.isHidden = true
        await nextMainTurn()
        return size
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class SummaryLayoutHostingController<Content: View>: UIHostingController<Content> {
    var onDidAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let completion = onDidAppear
        onDidAppear = nil
        completion?()
    }
}
