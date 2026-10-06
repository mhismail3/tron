import SwiftUI
@testable import TronMobileCore
import XCTest
@testable import TronMobile

/// Mounted `TimelineView` behavior the dashboard row clock depends on.
///
/// Failure modes: SwiftUI keeps iterating the previous clock after a row's
/// `updatedAt` changes, so a refreshed row stops ticking or keeps an hourly
/// cadence; or a row renders without its label changing. The schedule's
/// exact instants are owned by `PresentationLabelChangeTests`. Ticks are
/// awaited as events: a stalled host legitimately coalesces missed ticks into
/// the latest due one (#402), so the oracle never requires every second.
@MainActor
final class DashboardActivityClockHostedTests: XCTestCase {
    func testMountedClockRendersOnlyWhenTheLabelChangesAndFollowsNewTimestamps() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let model = DashboardClockFixtureModel(updatedAt: Date.now.addingTimeInterval(-7_200))
        let mounted = expectation(description: "Clock row rendered")
        model.onRender = { mounted.fulfill() }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        window.rootViewController = UIHostingController(rootView: DashboardClockFixture(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        // A two-hour-old row renders once on mount, then stays idle: its label
        // cannot change for an hour. A slow host can only hide extra renders.
        try await awaitHostedEvents([mounted])
        model.onRender = nil
        try await Task.sleep(for: .seconds(2.2))
        XCTAssertEqual(model.renders.count, 1, "\(model.renders)")

        // A newer timestamp replaces the clock: the row renders at once, then
        // follows the new timestamp's whole-second change instants.
        let ticked = expectation(description: "Refreshed row rendered and ticked twice")
        ticked.expectedFulfillmentCount = 3
        ticked.assertForOverFulfill = false
        model.onRender = { ticked.fulfill() }
        model.updatedAt = .now.addingTimeInterval(-3.5)
        // The instant the row parses from the millisecond Gateway timestamp.
        let refreshed = try XCTUnwrap(DashboardActivityClock(updatedAt: model.timestamp).updatedAt)
        try await awaitHostedEvents([ticked])
        model.onRender = nil

        let refreshedRenders = Array(model.renders.dropFirst())
        let secondsLabels = (3...59).map { GatewayTimestamp.relativeDescription(refreshed, relativeTo: refreshed.addingTimeInterval(Double($0))) }
        XCTAssertTrue(secondsLabels.contains(refreshedRenders[0].label), "\(model.renders)")
        var previous = refreshedRenders[0]
        for render in refreshedRenders.dropFirst() {
            // Each tick lands on a change instant: whole seconds after the new
            // timestamp, later than the last, with the label for that instant.
            let age = render.date.timeIntervalSince(refreshed)
            XCTAssertEqual(age, age.rounded(), accuracy: 0.000_1, "\(model.renders)")
            XCTAssertGreaterThan(render.date, previous.date, "\(model.renders)")
            XCTAssertEqual(render.label, GatewayTimestamp.relativeDescription(refreshed, relativeTo: render.date), "\(model.renders)")
            XCTAssertNotEqual(render.label, previous.label, "A render without a label change: \(model.renders)")
            previous = render
        }
    }
}

@MainActor
@Observable
private final class DashboardClockFixtureModel {
    struct Render {
        let date: Date
        let label: String
    }

    var updatedAt: Date
    @ObservationIgnored var renders: [Render] = []
    @ObservationIgnored var onRender: (() -> Void)?

    var timestamp: String { GatewayTimestamp.preciseString(from: updatedAt) }

    init(updatedAt: Date) {
        self.updatedAt = updatedAt
    }
}

private struct DashboardClockFixture: View {
    let model: DashboardClockFixtureModel

    var body: some View {
        // The same composition as `HistoricalSessionRow`.
        let clock = DashboardActivityClock(updatedAt: model.timestamp)
        TimelineView(clock) { timeline in
            let date = max(timeline.date, .now)
            let label = clock.label(relativeTo: date)
            let _ = model.renders.append(.init(date: timeline.date, label: label))
            let _ = model.onRender?()
            Text(label)
        }
    }
}
