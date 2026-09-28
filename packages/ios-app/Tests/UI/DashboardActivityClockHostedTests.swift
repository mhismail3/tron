import SwiftUI
import TronMobileCore
import XCTest
@testable import TronMobile

/// Mounted `TimelineView` behavior the dashboard row clock depends on.
///
/// Failure modes: SwiftUI keeps iterating the previous clock after a row's
/// `updatedAt` changes, so a refreshed row stops ticking or keeps an hourly
/// cadence; or a settled row still renders on a fixed cadence. The schedule's
/// exact instants are owned by `PresentationLabelChangeTests`.
@MainActor
final class DashboardActivityClockHostedTests: XCTestCase {
    func testMountedClockRendersOnlyWhenTheLabelChangesAndFollowsNewTimestamps() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let model = DashboardClockFixtureModel(updatedAt: Date.now.addingTimeInterval(-7_200))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        window.rootViewController = UIHostingController(rootView: DashboardClockFixture(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        // A two-hour-old row renders once on mount, then stays idle.
        try await waitUntil { !model.renders.isEmpty }
        try await Task.sleep(for: .seconds(2.2))
        XCTAssertEqual(model.renders.count, 1, "\(model.renders)")

        // A newer timestamp replaces the clock: the row renders at once, then
        // ages every second while the label counts seconds.
        model.updatedAt = .now.addingTimeInterval(-3.5)
        // The instant the row parses from the millisecond Gateway timestamp.
        let refreshed = try XCTUnwrap(DashboardActivityClock(updatedAt: model.timestamp).updatedAt)
        try await Task.sleep(for: .seconds(2.2))
        let labels = model.renders.dropFirst().map(\.label)
        let expected = (3...5).map { GatewayTimestamp.relativeDescription(refreshed, relativeTo: refreshed.addingTimeInterval(Double($0))) }
        XCTAssertEqual(Array(labels.prefix(3)), expected, "\(model.renders)")
        for render in model.renders.dropFirst(2) {
            // Each tick lands on its change instant: whole seconds after the timestamp.
            let age = render.date.timeIntervalSince(refreshed)
            XCTAssertEqual(age, age.rounded(), accuracy: 0.000_1, "\(model.renders)")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
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
            Text(label)
        }
    }
}
