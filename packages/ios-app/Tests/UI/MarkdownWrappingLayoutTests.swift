import SwiftUI
import XCTest
@testable import TronMobile

/// Native hosted capture of shared Markdown prose wrapping at a phone-width proposal.
@MainActor
final class MarkdownWrappingLayoutTests: XCTestCase {
    func testSoftWrapLayoutMatchesContinuousProseAtNarrowAndAccessibleSizes() {
        let lines = ["This prose", "has several", "short source", "lines but", "should flow", "at the reader's", "available width."]
        for width: CGFloat in [240, 346] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                let wrapped = measuredHeight(lines.joined(separator: "\n"), width: width, size: size)
                let continuous = measuredHeight(lines.joined(separator: " "), width: width, size: size)
                XCTAssertGreaterThan(wrapped, 0)
                XCTAssertEqual(wrapped, continuous, accuracy: 1)
            }
        }
        XCTAssertGreaterThan(
            measuredHeight("First  \nSecond", width: 346, size: .large),
            measuredHeight("First Second", width: 346, size: .large)
        )
    }

    private func measuredHeight(_ source: String, width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        let controller = UIHostingController(rootView:
            TronMarkdownView(document: MarkdownPresentation.Document(source: source), streaming: false)
                .environment(\.dynamicTypeSize, size)
        )
        return controller.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
    }

    func testREADMEStyleSoftWrapsFlowAtAvailableWidth() async throws {
        let source = [
            "# Work plans",
            "",
            "This folder holds work that spans more than one agent session. A plan is a",
            "living record of the work: any agent can pick it up, and every agent that works",
            "on it updates it with what was done, what came up and what is left.",
            "",
            "The folder contains only:",
            "",
            "- Proposed and active plans, one file each, named YYYY-MM-DD-<slug>.md.",
            "- HISTORY.md, one short entry for each finished or abandoned plan.",
            "  This continuation belongs to the same list item.",
            "",
            "A deliberate hard break  ",
            "is still a deliberate break.",
            "",
            "```text",
            "keep this source line",
            "and this one too",
            "```",
        ].joined(separator: "\n")
        let root = ScrollView {
            TronMarkdownView(document: MarkdownPresentation.Document(source: source), streaming: false)
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.tronSurface)
        .frame(width: 390, height: 760)
        .environment(\.dynamicTypeSize, .large)
        let controller = UIHostingController(rootView: root)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        controller.view.backgroundColor = UIColor(Color.tronSurface)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { context in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "markdown-prose-reflow-phone-width"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(image.size.width, 300)
        XCTAssertEqual(source, MarkdownPresentation.Document(source: source).source)
    }
}
