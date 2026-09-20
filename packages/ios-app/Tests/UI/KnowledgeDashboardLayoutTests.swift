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

        try await withHost(Self.hosted(KnowledgeRecordRow(record: record).frame(width: width)),
                           size: CGSize(width: 402, height: 200)) { host in
            Self.attach(host.view, named: "knowledge-catalogue-row", to: self)
        }

        // The changed regions composed the way the dashboard stacks them; an
        // honest preview of catalogue density, not a live Gateway screenshot.
        let composition = VStack(alignment: .leading, spacing: KnowledgeDashboardLayout.recordSpacing) {
            Self.overview()
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
            guard !rows.isEmpty else { throw XCTSkip("Hosted SwiftUI accessibility tree unavailable in this simulator runtime") }
            XCTAssertEqual(rows.count, Self.previewStatements.count)
            for (previous, next) in zip(rows, rows.dropFirst()) {
                XCTAssertEqual(next.frame.minY - previous.frame.maxY, KnowledgeDashboardLayout.recordSpacing, accuracy: 1,
                               "Catalogue rows pack tighter than the dashboard's section rhythm")
            }
            XCTAssertLessThan(KnowledgeDashboardLayout.recordSpacing, TronSpacing.section)
        }
    }

    func testSourceRowsAndDetailsRenderAcrossThemesAndNarrowWidth() async throws {
        let source = Self.sourceRecord()
        let width: CGFloat = 320
        XCTAssertLessThanOrEqual(Self.intrinsicHeight(KnowledgeRecordRow(record: source), width: width), 150)
        XCTAssertEqual(KnowledgeSourcePresentationPolicy.domain("https://example.test/article"), "example.test")
        for (scheme, label) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            try await withHost(Self.hosted(KnowledgeRecordRow(record: source).frame(width: width)), size: CGSize(width: width, height: 220), scheme: scheme) { host in
                Self.attach(host.view, named: "knowledge-source-row-\(label)-narrow", to: self)
            }
            let model = AppModel()
            let detail = KnowledgeDetailSheet(record: source, origin: KnowledgePresentationIdentity(profileID: "fixture", lifecycleGeneration: 1, connectionID: 1), onChanged: {}, onOpenDraft: { _ in }, onOpenSession: { _, _ in })
                .environment(model)
            try await withHost(Self.hosted(detail), size: CGSize(width: width, height: 700), scheme: scheme) { host in
                Self.attach(host.view, named: "knowledge-source-detail-\(label)-narrow", to: self)
            }
        }
    }

    func testCoverageOverviewIsInformationalAndOpensTheDetailSheet() async throws {
        let overview = Self.overview()
        XCTAssertLessThanOrEqual(Self.intrinsicHeight(overview, width: 402),
                                 KnowledgeDashboardLayout.coverageSectionReservedHeight,
                                 "The overview must fit the height the dashboard reserves for it")

        try await withHost(Self.hosted(overview), size: CGSize(width: 402, height: 200)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            guard !elements.isEmpty else { throw XCTSkip("Hosted SwiftUI accessibility tree unavailable in this simulator runtime") }
            XCTAssertTrue(elements.contains { $0.label == "Observed 367 · Empty 3 · Excluded 27" },
                          "The overview reports the settled breakdown")
            let attention = elements.filter { $0.label == "6 cuts need attention" }
            XCTAssertEqual(attention.count, 1, "The cuts needing attention are one button")
            XCTAssertTrue(try XCTUnwrap(attention.first).traits.contains(.button))
            XCTAssertFalse(elements.contains { $0.label == "Open originating session" },
                           "The overview carries no cut actions; those belong to the sheet")
            XCTAssertFalse(elements.contains { $0.label == "Clear observation failure" })
            Self.attach(host.view, named: "knowledge-coverage-overview", to: self)
        }

        // Nothing to act on: the card stays informational, with no button.
        try await withHost(Self.hosted(Self.overview(Self.coverage(remaining: 0, failed: 0, unavailable: 0))),
                           size: CGSize(width: 402, height: 200)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            XCTAssertTrue(elements.contains { $0.label == "No cuts need attention" })
            XCTAssertFalse(elements.contains { $0.traits.contains(.button) })
        }

        // A paired Gateway that cannot filter coverage states that instead of
        // offering a button with no list behind it.
        try await withHost(Self.hosted(Self.overview(requiresGatewayUpdate: true)),
                           size: CGSize(width: 402, height: 220)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            XCTAssertFalse(elements.contains { $0.traits.contains(.button) },
                           "A Gateway without the filter offers no coverage control")
            XCTAssertTrue(elements.contains { $0.label.contains("Update this Gateway to list the cuts that need attention.") })
        }
    }

    func testCoverageDetailSheetListsEveryCutWithItsOwnActions() async throws {
        try await withHost(Self.detailSheet(), size: CGSize(width: 402, height: 620)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            guard !elements.isEmpty else { throw XCTSkip("Hosted SwiftUI accessibility tree unavailable in this simulator runtime") }
            let opens = elements.filter { $0.label == "Open originating session" }
            let clears = elements.filter { $0.label == "Clear observation failure" }
            XCTAssertEqual(opens.count, 2, "The sheet lists every cut needing attention")
            XCTAssertEqual(clears.count, 2)
            for target in opens + clears {
                XCTAssertGreaterThanOrEqual(target.frame.height, 44, "Each cut action keeps a full tap target")
            }
            for (open, clear) in zip(opens, clears) {
                XCTAssertFalse(open.frame.intersects(clear.frame), "Open and Clear must stay distinct targets")
            }
            XCTAssertTrue(elements.contains { $0.label == "Done" }, "The sheet uses the standard Done control")
            Self.attach(host.view, named: "knowledge-coverage-detail", to: self)
        }

        // More cuts need attention than the loaded page holds: the sheet says
        // how many it is showing and offers the only control that helps.
        try await withHost(Self.detailSheet(coverage: Self.coverage(remaining: 6, failed: 1, unavailable: 1), canLoadMore: true),
                           size: CGSize(width: 402, height: 620)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            XCTAssertTrue(elements.contains { $0.label == "Showing 2 of 6 cuts needing attention." },
                          "The sheet states that the list is partial")
            XCTAssertTrue(elements.contains { $0.label == "Load more cuts needing attention" },
                          "Paging is offered under a label that says what it does")
        }
    }

    private static func overview(
        _ coverage: KnowledgeCoverageSummary? = nil,
        requiresGatewayUpdate: Bool = false
    ) -> some View {
        KnowledgeCoverageOverview(
            coverage: coverage ?? Self.coverage(remaining: 6, failed: 1, unavailable: 1),
            requiresGatewayUpdate: requiresGatewayUpdate,
            onOpen: {}
        )
        .tronPresentation()
    }

    /// A mounted component on the dashboard's background, top-aligned so a
    /// capture shows the geometry under test rather than a centered card.
    private static func hosted(_ content: some View) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.tronBackground)
            .tronPresentation()
    }

    private static func detailSheet(
        coverage: KnowledgeCoverageSummary? = nil,
        canLoadMore: Bool = false
    ) -> some View {
        KnowledgeCoverageDetailSheet(
            coverage: coverage ?? Self.coverage(remaining: 2, failed: 1, unavailable: 1),
            cuts: cuts(),
            showsInitialLoading: false,
            loadingMore: false,
            canLoadMore: canLoadMore,
            errorText: nil,
            mutationErrorText: nil,
            clearingCutID: nil,
            allowsActions: true,
            onOpenSession: { _ in },
            onClear: { _ in },
            onLoadMore: {}
        )
        .background(Color.tronBackground)
        .tronPresentation()
    }

    private struct Element {
        let label: String
        let traits: UIAccessibilityTraits
        let frame: CGRect
    }

    /// Walks the whole hosted tree: a scrollable sheet exposes its controls on
    /// nested containers, not only at the root.
    private static func accessibilityElements(in view: UIView) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        var collected: [Element] = []
        func walk(_ view: UIView) {
            for element in view.accessibilityElements ?? [] {
                guard let object = element as? NSObject else { continue }
                if seen.insert(ObjectIdentifier(object)).inserted {
                    collected.append(Element(label: object.accessibilityLabel ?? "", traits: object.accessibilityTraits,
                                             frame: object.accessibilityFrame))
                }
                if let nested = element as? UIAccessibilityElement, let container = nested.accessibilityContainer as? UIView {
                    walk(container)
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(view)
        return collected
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
        _ content: Content, size: CGSize, scheme: ColorScheme = .dark,
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
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
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

    /// The Gateway returns only cuts needing attention, so a settled cut is not a
    /// fixture input here; the client boundary rejects one that ignores the
    /// disposition filter.
    private static func sourceRecord() -> KnowledgeRecord {
        let hash = String(repeating: "d", count: 64)
        return KnowledgeRecord(schemaVersion: 1, id: "fixture-source", revisionId: "fixture-source-revision", kind: .source, scope: .research,
                               createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                               provenance: KnowledgeProvenance(actor: .connector, source: "fixture-provider", sessionId: nil, branchId: nil, invocationId: nil, evidence: []), temporal: nil, relations: [],
                               content: .source(KnowledgeSourceContent(title: "Fixture retained article", uri: "https://example.test/article", text: "Captured fixture text only; this is not a live source.", object: KnowledgeObjectRef(hash: hash, mediaType: "text/plain", bytes: 50), mediaType: "text/plain", captureDisposition: .complete, annotations: nil, sourcePublishedAt: nil, capturedAt: "2026-01-01T00:00:00Z", origin: "connector", origins: [KnowledgeSourceOrigin(kind: .connector, capturedAt: "2026-01-01T00:00:00Z", annotation: "Synthetic hosted UI fixture", uri: "https://example.test/article", identity: nil)], identity: nil, assessment: KnowledgeSourceAssessment(summary: "Fixture assessment", contribution: "Fixture contribution", whyItMatters: "Fixture only", evidenceQuality: .unknown, freshness: .unknown, possibleUse: "Fixture", generatedAt: "2026-01-01T00:00:00Z", model: "fixture/model", coverage: "full", classification: "fixture"))))
    }

    private static func cuts() -> [KnowledgeObservationCoverage] {
        let range = KnowledgeObservationPresentation(record: KnowledgeObservationFixture.record())!.observation.range
        return [
            cut("failed-cut", .failed, range: range, reason: "entry-exceeds-model-input-bound"),
            cut("unavailable-cut", .unavailable, range: range, reason: "provider-credentials-unavailable"),
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

