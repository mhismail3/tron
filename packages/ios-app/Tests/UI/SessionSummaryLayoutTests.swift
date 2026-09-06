import SwiftUI
import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SessionSummaryLayoutTests: XCTestCase {
    func testUsageSummaryKeepsOneCompactHeaderAndStatsBand() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_810).openingTail(targetEncodedBytes: 4_096)
        snapshot.contextUsage = ContextUsage(tokens: 162_000, contextWindow: 272_000, percent: 60)
        for scheme: ColorScheme in [.light, .dark] {
            let size = try await render(
                SessionContextUsageCard(snapshot: SessionContextPresentation(snapshot))
                    .environment(\.colorScheme, scheme),
                width: 404,
                name: "usage-summary-\(scheme)"
            )
            XCTAssertEqual(size.width, 404, accuracy: 1)
            // Header + progress separator + metric band, including card padding.
            // The former extra context/compaction row and divider exceed this.
            XCTAssertLessThan(size.height, 130)
            XCTAssertGreaterThan(size.height, 90)
        }
    }

    func testCommandResourcePreviewDoesNotBecomeATallSourceContainer() async throws {
        for source: CommandInfo.Source in [.extension, .prompt] {
            let text = String(repeating: "Read the selected resource before continuing. ", count: 1_500)
            let preview = ComposerResourceContentPresentation.preview(text, source: source, sourceTruncated: true)
            let size = try await render(
                ComposerResourceContentBody(preview: preview, source: source)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronScrollSurface(accent: .tronPurple, cornerRadius: 16, tintOpacity: 0.06),
                width: 320, name: "resource-preview-\(source)"
            )
            XCTAssertEqual(size.width, 320, accuracy: 1)
            XCTAssertLessThan(size.height, 350, "Source previews should not render the transport's 96-KiB body")
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
            ContextWindowSelectionRow(
                selection: .constant(nil),
                limits: ContextWindowLimits(minimum: 1_000, maximum: 1_048_576, default: 272_000, longContextThreshold: nil),
                inheritedValue: 272_000, effectiveValue: 272_000,
                resetLabel: "Use configured default", source: "model", accent: .tronEmerald
            )
            TronSettingsDivider(accent: .tronEmerald)
            TronThinkingSelectionRow(selection: .constant("xhigh"), levels: ["off", "high", "xhigh"], accent: .tronEmerald)
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
                            subtitle: "Enabled", subtitleRole: .dynamicValue)
                .environment(\.tronSettingsSecondaryTextSizeAdjustment, adjustment), width: 404
        )
        let compaction = try await render(
            TronSettingsRow(icon: "rectangle.compress.vertical", title: "Automatic Compaction",
                            subtitle: "Enabled", subtitleRole: .dynamicValue) {
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
        XCTAssertEqual(SessionSummaryTypography.value, TronTypography.code(size: TronTypography.sizeSecondary + 0.5))
        // Values and captions share the same point scale, not necessarily the same family/weight.
        XCTAssertEqual(SessionSummaryTypography.metric, TronTypography.code(size: TronTypography.sizeSecondary + 0.5, weight: .semibold))
        XCTAssertEqual(SessionSummaryTypography.headline, TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
        XCTAssertEqual(TronSettingsSecondaryRole.informational.font, TronTypography.secondaryDescription)
    }

    private func render<Content: View>(_ content: Content, width: CGFloat, name: String? = nil) async throws -> CGSize {
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
        if let name {
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
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
