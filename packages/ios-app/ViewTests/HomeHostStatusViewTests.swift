import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeHostStatusViewTests: ShuffledTestCase {
    func testHostPressureNormalAndIdleWorkers() async throws {
        try await checkHostStatus(level: "Normal", workers: "0 workers running", arguments: [])
    }

    func testHostPressureElevatedAndSingleWorkerInDarkMode() async throws {
        try await checkHostStatus(level: "Elevated", workers: "1 worker running", arguments: ["-host-elevated", "-home-dark"])
    }

    func testHostPressureCriticalAndUncappedWorkersAtLargeText() async throws {
        try await checkHostStatus(level: "Critical", workers: "7 workers running", arguments: ["-host-critical"],
                                  contentSize: .accessibilityExtraExtraExtraLarge)
    }

    func testSummaryAndChapterTagsFitAtXXXL() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"], contentSize: .extraExtraExtraLarge) { app in
            try await openManageHome(app)
            try await assertCompactSummary(app, level: "Normal", workers: "0 workers")
            let summary = app.element("home-context-summary")!.accessibilityFrame
            for id in ["home-context-ring", "home-context-detail"] {
                XCTAssertTrue(summary.contains(app.element(id)!.accessibilityFrame), "\(id) stays inside the compact summary at XXXL")
            }
            _ = try await revealed(app, "home-manage-chapters")
            try await app.activate("home-manage-chapters")
            try await app.until("Chapters opens") { app.element("home-chapter-list") != nil }
            try await app.expandTopSheet()
            try await app.activate("home-chapter-2")
            try await app.until("chapter 2 opens") {
                app.element("home-chapter-detail") != nil && app.element("home-chapter-stats") != nil
                    && app.element("home-chapter-size") != nil && app.element("home-chapter-header") != nil
            }
            try await app.expandTopSheet()
            let header = app.element("home-chapter-header")!.accessibilityFrame
            let size = app.element("home-chapter-size")!.accessibilityFrame
            let stats = app.element("home-chapter-stats")!.accessibilityFrame
            let tags = MountedFixture.elements(in: app.top).filter { node in
                node.isAccessibilityElement && !(node.accessibilityLabel ?? "").isEmpty
                    && !node.accessibilityTraits.contains(.button)
                    && stats.contains(CGPoint(x: node.accessibilityFrame.midX, y: node.accessibilityFrame.midY))
            }
            XCTAssertEqual(tags.count, 3, "Chapter stats: \(tags.map { $0.accessibilityLabel ?? "" })\n\(app.tree())")
            for phrase in ["user message", "Home repl", "task"] {
                XCTAssertTrue(tags.contains { $0.accessibilityLabel?.contains(phrase) == true }, "Chapter misses \(phrase)")
            }
            XCTAssertGreaterThanOrEqual(stats.minY, size.maxY)
            XCTAssertLessThanOrEqual(stats.maxY, header.maxY)
            for tag in tags {
                XCTAssertGreaterThanOrEqual(tag.accessibilityFrame.minX, header.minX)
                XCTAssertLessThanOrEqual(tag.accessibilityFrame.maxX, header.maxX)
            }
            XCTAssertGreaterThan(Set(tags.map { $0.accessibilityFrame.minY.rounded() }).count, 1, "Tags wrap rather than clip at XXXL")
        }
    }

    private func checkHostStatus(level: String, workers: String, arguments: [String],
                                 contentSize: UIContentSizeCategory = .large) async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"] + arguments, contentSize: contentSize) { app in
            try await app.until("the Home row shows host status") {
                app.element("home-pinned-row")?.accessibilityLabel?.contains("Host ") == true
            }
            let label = app.element("home-pinned-row")!.accessibilityLabel ?? ""
            XCTAssertTrue(label.contains("Host \(level.lowercased())"), label)
            XCTAssertTrue(label.contains(workers), label)
            try await openManageHome(app)
            try await assertCompactSummary(app, level: level, workers: workers.replacingOccurrences(of: " running", with: ""))
        }
    }

    private func assertCompactSummary(_ app: MountedFixture, level: String, workers: String) async throws {
        let ids = ["home-context-summary", "home-manage-workers", "home-manage-state", "home-context-ring", "home-context-detail"]
        try await app.until("the Home summary") { ids.allSatisfy { app.element($0) != nil } }
        for removed in ["home-context-activation", "context-segmented-bar", "home-manage-host",
                        "context-segment-instructions", "context-segment-profile", "context-segment-memory",
                        "context-segment-chapter", "context-segment-results", "context-segment-input"] {
            XCTAssertNil(app.element(removed), "Removed Home-only summary content: \(removed)")
        }
        let summary = app.element("home-context-summary")!.accessibilityFrame
        for metric in ["Read / Write", "Input", "Output", "Cost"] {
            XCTAssertFalse(MountedFixture.elements(in: app.top).contains {
                $0.accessibilityLabel == metric && !$0.accessibilityTraits.contains(.button)
                    && summary.contains(CGPoint(x: $0.accessibilityFrame.midX, y: $0.accessibilityFrame.midY))
            }, "Home does not show the session's \(metric) metric")
        }
        let pillNode = app.element("home-manage-workers")!
        let pill = pillNode.accessibilityFrame, state = app.element("home-manage-state")!.accessibilityFrame
        XCTAssertEqual(pillNode.accessibilityLabel, workers)
        XCTAssertTrue(pillNode.accessibilityValue?.lowercased().contains(level.lowercased()) == true)
        XCTAssertGreaterThanOrEqual(pill.minX, state.maxX)
        XCTAssertEqual(pill.midY, state.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(pill.maxX, app.window.bounds.maxX)
        let color = try await app.inked("the workers pill") { app.element("home-manage-workers")?.accessibilityFrame }
        switch level {
        case "Normal":
            XCTAssertGreaterThan(color[1], color[0] + 0.1)
        case "Elevated":
            XCTAssertGreaterThan(color[0], color[2] + 0.15)
            XCTAssertGreaterThan(color[1], color[2] + 0.1)
        default:
            XCTAssertGreaterThan(color[0], color[1] + 0.2)
            XCTAssertGreaterThan(color[0], color[2] + 0.2)
        }
        let ringNode = app.element("home-context-ring")!, ring = ringNode.accessibilityFrame
        XCTAssertEqual(ringNode.accessibilityValue, "3 percent")
        XCTAssertEqual(ring.width, ring.height, accuracy: 0.5)
        let title = try XCTUnwrap(MountedFixture.elements(in: app.top).last {
            $0.accessibilityLabel == "969K tokens left" && !$0.accessibilityTraits.contains(.button)
        }, app.tree())
        XCTAssertLessThan(ring.maxX, title.accessibilityFrame.minX)
        let detail = (app.element("home-context-detail")!.accessibilityLabel ?? "").replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertTrue(detail.contains("31K/1M") && detail.contains("3% used"), detail)
        XCTAssertTrue(detail.contains("1.8M total tokens") && detail.contains("91.4% cache hit"), detail)
        XCTAssertFalse(MountedFixture.elements(in: app.top).contains { MountedFixture.identifier($0) == "chevron.right" },
                       "Manage Home rows carry no trailing chevron")
    }
}
