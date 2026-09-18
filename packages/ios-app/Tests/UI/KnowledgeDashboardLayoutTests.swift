import SwiftUI
import XCTest
@testable import TronMobile

/// Native captures of the real Knowledge catalogue row and coverage container.
/// These are layout and interaction checks, not physical-device visual acceptance.
@MainActor
final class KnowledgeDashboardLayoutTests: XCTestCase {
    func testCatalogueRowStaysCompactAndCapsItsStatement() async throws {
        let record = Self.observationRecord(statement: Self.wrappingStatement)
        let presentation = try XCTUnwrap(KnowledgeObservationPresentation(record: record))
        let width: CGFloat = 362
        let previewHeight = Self.intrinsicHeight(
            KnowledgeObservationStatement(presentation: presentation, preview: true), width: width)
        let fullHeight = Self.intrinsicHeight(
            KnowledgeObservationStatement(presentation: presentation, preview: false), width: width)
        XCTAssertLessThan(previewHeight, fullHeight, "The catalogue statement keeps one type step below the detail sheet")

        let threeLineRow = Self.intrinsicHeight(
            KnowledgeRecordRow(record: Self.observationRecord(statement: Self.wrappingStatement)), width: width)
        let shortRow = Self.intrinsicHeight(
            KnowledgeRecordRow(record: Self.observationRecord(statement: "The user prefers concise explanations.")), width: width)
        let runawayRow = Self.intrinsicHeight(
            KnowledgeRecordRow(record: Self.observationRecord(statement: String(repeating: "Long retained statement. ", count: 40))), width: width)
        XCTAssertLessThan(shortRow, threeLineRow)
        XCTAssertEqual(runawayRow, threeLineRow, accuracy: 1, "A long statement is capped instead of growing the row")
        XCTAssertLessThanOrEqual(threeLineRow, 100, "Catalogue rows must stay dense enough to show several per screen")

        try await withHost(KnowledgeRecordRow(record: record).tronPresentation().frame(width: width)
            .padding(20).background(Color.tronBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top),
            size: CGSize(width: 402, height: 200)) { host in
            Self.attach(host.view, named: "knowledge-catalogue-row", to: self)
        }

        // The changed regions composed the way the dashboard stacks them; an
        // honest preview of catalogue density, not a live Gateway screenshot.
        let composition = VStack(alignment: .leading, spacing: KnowledgeDashboardLayout.recordSpacing) {
            Self.section(cuts: Self.cuts(), expanded: false)
            Text("All knowledge").font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronKnowledge)
                .padding(.top, TronSpacing.md)
            ForEach(Array(Self.previewStatements.enumerated()), id: \.offset) { _, statement in
                KnowledgeRecordRow(record: Self.observationRecord(statement: statement))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.tronBackground)
        .tronPresentation()
        try await withHost(composition, size: CGSize(width: 402, height: 874)) { host in
            Self.attach(host.view, named: "knowledge-catalogue-density", to: self)
            let rows = Self.accessibilityElements(in: host.view).filter { $0.label.contains("Personal") }
            XCTAssertEqual(rows.count, Self.previewStatements.count)
            for (previous, next) in zip(rows, rows.dropFirst()) {
                XCTAssertEqual(next.frame.minY - previous.frame.maxY, KnowledgeDashboardLayout.recordSpacing, accuracy: 1,
                               "Catalogue rows pack tighter than the dashboard's section rhythm")
            }
            XCTAssertLessThan(KnowledgeDashboardLayout.recordSpacing, TronSpacing.section)
        }
    }

    func testCoverageContainerCollapsesToASummaryAndKeepsCutActionsSeparate() async throws {
        let cuts = Self.cuts()
        let collapsed = Self.section(cuts: cuts, expanded: false)
        let expanded = Self.section(cuts: cuts, expanded: true)
        let collapsedHeight = Self.intrinsicHeight(collapsed, width: 402)
        let expandedHeight = Self.intrinsicHeight(expanded, width: 402)
        XCTAssertLessThanOrEqual(collapsedHeight, 100, "A collapsed coverage container costs one summary row")
        XCTAssertGreaterThan(expandedHeight, collapsedHeight + 120, "Expanding reveals the actionable cuts")

        try await withHost(collapsed.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top),
                           size: CGSize(width: 402, height: 200)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            XCTAssertEqual(elements.filter { $0.label == "Observation coverage" && $0.traits.contains(.button) }.count, 1,
                           "The summary row is one disclosure control")
            let summary = try XCTUnwrap(elements.first { $0.label == "Observation coverage" && $0.traits.contains(.button) })
            XCTAssertLessThanOrEqual(summary.frame.height, 72)
            XCTAssertFalse(elements.contains { $0.label == "Open originating session" },
                           "Collapsed coverage must not expose hidden cut actions")
            Self.attach(host.view, named: "knowledge-coverage-collapsed", to: self)
        }

        try await withHost(expanded.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top),
                           size: CGSize(width: 402, height: 560)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            let opens = elements.filter { $0.label == "Open originating session" }
            let clears = elements.filter { $0.label == "Clear observation failure" }
            // Two failing/unavailable cuts; the observed cut is not an attention row.
            XCTAssertEqual(opens.count, 2)
            XCTAssertEqual(clears.count, 2)
            for target in opens + clears {
                XCTAssertGreaterThanOrEqual(target.frame.height, 44, "Each cut action keeps a full tap target")
            }
            for index in 0..<2 {
                XCTAssertFalse(opens[index].frame.intersects(clears[index].frame),
                               "Open and Clear must stay distinct targets")
            }
            Self.attach(host.view, named: "knowledge-coverage-expanded", to: self)
        }
    }

    private static func section(cuts: [KnowledgeObservationCoverage], expanded: Bool) -> some View {
        KnowledgeCoverageSection(
            coverage: coverage(remaining: 2, failed: 1, unavailable: 1),
            cuts: cuts,
            showsInitialLoading: false,
            loadingMore: false,
            canLoadMore: true,
            errorText: nil,
            mutationErrorText: nil,
            clearingCutID: nil,
            allowsActions: true,
            onOpenSession: { _ in },
            onRequestClear: { _ in },
            onLoadMore: {},
            expanded: .constant(expanded)
        )
        .tronPresentation()
        .background(Color.tronBackground)
    }

    private struct Element {
        let label: String
        let traits: UIAccessibilityTraits
        let frame: CGRect
    }

    private static func accessibilityElements(in view: UIView) -> [Element] {
        (view.accessibilityElements ?? []).compactMap { element in
            guard let object = element as? NSObject else { return nil }
            return Element(label: object.accessibilityLabel ?? "", traits: object.accessibilityTraits,
                           frame: object.accessibilityFrame)
        }
    }

    private static func intrinsicHeight(_ content: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: content)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private static func attach(_ view: UIView, named name: String, to testCase: XCTestCase) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    private func withHost<Content: View>(
        _ content: Content, size: CGSize,
        check: (UIHostingController<Content>) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Knowledge fixture appeared")
        let host = KnowledgeLayoutHostingController(rootView: content)
        host.onAppear = { appeared.fulfill() }
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [appeared], timeout: 2)
        host.view.layoutIfNeeded()
        try await check(host)
    }

    /// Wraps to the three-line preview cap at a 362-point catalogue row width.
    private static let wrappingStatement = "User requested moving aggregation changes to a separate feature branch and restoring main to the latest commit where the changes remained separate."

    private static let previewStatements = [
        "Assistant stated that main was moved back to commit 0f8b4ac2d, preserving separate chips and original sheets.",
        "Assistant stated that the working tree was clean and no changes were pushed.",
        "Assistant stated that aggregation commits b115b3438 and 1c256b8e3 were preserved on feature/aggregated-extension-chips.",
        "User requested moving aggregation changes to a separate feature branch and restoring main to the latest commit where the changes remained separate.",
        "Aggregated chips appear when two or more eligible chips are consecutive; a lone chip retains its normal appearance and original detail sheet.",
    ]

    private static func observationRecord(statement: String) -> KnowledgeRecord {
        let base = KnowledgeObservationFixture.record()
        guard case .observation(let content) = base.content, let item = content.items.first else { return base }
        return KnowledgeRecord(
            schemaVersion: base.schemaVersion, id: base.id, revisionId: base.revisionId, kind: base.kind,
            scope: base.scope, createdAt: base.createdAt, updatedAt: base.updatedAt,
            provenance: base.provenance, temporal: nil, relations: [],
            content: .observation(KnowledgeObservationContent(
                range: content.range,
                items: [KnowledgeObservationItem(text: statement, attribution: item.attribution,
                                                 observedAt: item.observedAt, certainty: item.certainty,
                                                 evidence: nil, field: nil)],
                observer: content.observer
            ))
        )
    }

    private static func cuts() -> [KnowledgeObservationCoverage] {
        let range = KnowledgeObservationPresentation(record: KnowledgeObservationFixture.record())!.observation.range
        return [
            cut("failed-cut", .failed, range: range, reason: "entry-exceeds-model-input-bound"),
            cut("unavailable-cut", .unavailable, range: range, reason: "provider-credentials-unavailable"),
            cut("observed-cut", .observed, range: range, reason: nil),
        ]
    }

    private static func cut(
        _ id: String, _ disposition: KnowledgeCoverageDisposition,
        range: KnowledgeObservationRange, reason: String?
    ) -> KnowledgeObservationCoverage {
        KnowledgeObservationCoverage(
            schemaVersion: 1, id: id, revisionId: "\(id)-revision", range: range,
            disposition: disposition, groupRevisionIds: [], recordedAt: "2026-01-01T00:00:00Z", reason: reason
        )
    }

    private static func coverage(remaining: Int, failed: Int, unavailable: Int) -> KnowledgeCoverageSummary {
        KnowledgeCoverageSummary(
            observedCount: 367, emptyCount: 3, excludedCount: 27,
            pendingCount: remaining - failed - unavailable, failedCount: failed,
            unavailableCount: unavailable, remainingCount: remaining
        )
    }
}

@MainActor
private final class KnowledgeLayoutHostingController<Content: View>: UIHostingController<Content> {
    var onAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }
}
