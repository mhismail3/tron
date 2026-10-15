import Foundation
import QuartzCore
import SwiftUI
@testable import TronMobileCore
import UIKit
import XCTest
@testable import TronMobile

/// The Home view's Recently Completed sheet for `scripts/tron-profile ios`:
/// the production `SessionShellView` in its Home view over a catalog of Home
/// workers, while two running workers publish a summary every second. Each
/// cycle opens the sheet through its own control, scrolls it to the end and
/// back at a steady speed, and closes it through Done. The ledger records the
/// open latency and the display frames the main thread missed (#1003).
@MainActor
final class ProfileHomeSheetScenarioTests: XCTestCase {
    func testHomeCompletedSheet() throws {
        try profileScenario("home-sheet", defaultWindow: .seconds(14)) { _ in
            try await ProfileHomeSheetRun.make()
        }
    }
}

@MainActor
final class ProfileHomeSheetRun: ProfileScenarioRun {
    static let completedCount = 40
    static let unreadCount = 8
    static let runningCount = 2
    /// The section's control: "View All" in its header, formerly "View more"
    /// below its rows. SwiftUI's accessibility nodes publish labels, not identifiers.
    static let openLabels: Set<String> = ["View all sessions in Recently Completed", "View more sessions in Recently Completed"]
    static let sheetRowPrefix = "home-completed-sheet-row-"

    private let fixture: ProfileGatewayFixture
    private var sessions: [SessionSummary]
    private var host: UIHostingController<AnyView>?
    private var cycles = 0
    /// The dashboard reads its view choice from standard defaults; the run
    /// selects the Home view and restores the host's choice afterwards.
    private let savedFilter = UserDefaults.standard.data(forKey: DashboardServerFilterPreferences.documentKey)

    private init(fixture: ProfileGatewayFixture) {
        self.fixture = fixture
        let names = ["Settings model epic report", "Garden review email draft", "Kitchen countertop bids",
                     "Quarterly budget summary", "Push relay certificate check", "Raindrop triage"]
        let now = Date()
        func stamp(_ secondsAgo: Double) -> String { GatewayTimestamp.preciseString(from: now.addingTimeInterval(-secondsAgo)) }
        var rows: [SessionSummary] = []
        let total = Self.runningCount + Self.completedCount + Self.unreadCount
        for index in 0..<total {
            let running = index < Self.runningCount
            let unread = index >= Self.runningCount + Self.completedCount
            // Ages spread from minutes to weeks, so the rows show every relative-time unit.
            let ago = 45 * pow(1.25, Double(index))
            rows.append(SessionSummary(
                id: String(format: "home-worker-%02d", index), name: "\(names[index % names.count]) \(index)",
                cwd: "/workspace/tron", parentSessionId: nil, homeTaskId: String(format: "task-%02d", index),
                createdAt: stamp(ago + 600), updatedAt: stamp(ago), activeSince: running ? stamp(90) : nil,
                messageCount: 6 + index, firstMessage: "Home worker fixture row \(index)",
                phase: running ? .running : .idle, foregroundPhase: running ? .running : nil,
                summaryRevision: 1, completionRevision: unread ? 1 : 0, isUnread: unread
            ))
        }
        sessions = rows
    }

    static func make() async throws -> ProfileHomeSheetRun {
        ProfileScenarioLedger.shared.reset()
        for name in ["sheet.opens", "sheet.open_ms", "sheet.open_missed_frames", "sheet.scroll_frames",
                     "sheet.scroll_missed_frames", "sheet.scroll_missed_ms", "summaries.delivered"] {
            ProfileScenarioLedger.shared.add(name, 0)
        }
        ProfileAccessibility.enableAutomation()
        let fixture = try ProfileGatewayFixture()
        let run = ProfileHomeSheetRun(fixture: fixture)
        DashboardServerFilterPreferences.save(DashboardServerFilterState(sortMode: .home))
        do {
            let listed = try JSONValue.encode(run.sessions)
            fixture.handle("session.list") { _ in .object(["sessions": listed, "listRevision": .number(1), "projectionToken": .string("epoch-1:1")]) }
            try await fixture.connect()
            guard await fixture.model.refreshSessions() == .published else {
                throw ProfileScenarioError.notReady("session.list did not publish the fixture catalog")
            }
            run.host = try fixture.mount(SessionShellView())
        } catch {
            await run.teardown()
            throw error
        }
        return run
    }

    func ready() async throws {
        guard let view = host?.view else { throw ProfileScenarioError.notReady("dashboard is not mounted") }
        try await profileWaitUntil("the Home view shows Recently Completed's sheet control") {
            fixture.model.sessions.count == sessions.count && ProfileAccessibility.element(in: view, labels: Self.openLabels) != nil
        }
        // Let the sections' first-appearance stagger finish.
        try await Task.sleep(for: .seconds(2))
    }

    func workload(window: Duration) async throws {
        let start = ContinuousClock.now
        let deadline = window - ProfileChatRun.drainTail
        let heartbeat = Task { @MainActor in try await self.publishSummaries(until: deadline, from: start) }
        defer { heartbeat.cancel() }
        while ContinuousClock.now - start < deadline - .seconds(4) {
            try await cycle()
            cycles += 1
        }
        try await heartbeat.value
        try await profileSleep(until: window, from: start)
    }

    /// Running workers publish as the Gateway does while they work.
    private func publishSummaries(until deadline: Duration, from start: ContinuousClock.Instant) async throws {
        var revision = 1
        var offset = Duration.seconds(1)
        while offset < deadline {
            try await profileSleep(until: offset, from: start)
            revision += 1
            for session in sessions.prefix(Self.runningCount) {
                let update = SessionSummaryUpdate(
                    sessionId: session.id, summaryRevision: revision, phase: .running, name: session.name,
                    updatedAt: GatewayTimestamp.preciseString(from: Date()), activeSince: session.activeSince,
                    messageCount: session.messageCount + revision, firstMessage: session.firstMessage
                )
                try await fixture.deliver(topic: "session.summary", sessionID: nil, payload: JSONValue.encode(update))
                ProfileScenarioLedger.shared.add("summaries.delivered")
            }
            offset += .seconds(1)
        }
    }

    private func cycle() async throws {
        guard let view = host?.view,
              let control = ProfileAccessibility.element(in: view, labels: Self.openLabels) else {
            throw ProfileScenarioError.workloadDiverged("the sheet control is not on screen")
        }
        let frames = ProfileFrameClock()
        frames.start()
        defer { frames.stop() }
        let opened = CACurrentMediaTime()
        guard control.accessibilityActivate() else { throw ProfileScenarioError.workloadDiverged("the sheet control refused activation") }
        // Open: until the presented sheet lists its rows and its presentation settled.
        var scroll: UIScrollView?
        try await profileWaitUntil("the sheet lists its rows", timeout: .seconds(5)) {
            scroll = self.sheetScrollView()
            guard let presented = self.host?.presentedViewController, !presented.isBeingPresented,
                  presented.transitionCoordinator == nil, let scroll else { return false }
            return scroll.contentSize.height > scroll.bounds.height
        }
        ProfileScenarioLedger.shared.add("sheet.opens")
        ProfileScenarioLedger.shared.add("sheet.open_ms", Int((CACurrentMediaTime() - opened) * 1_000))
        ProfileScenarioLedger.shared.add("sheet.open_missed_frames", frames.takeMissed().frames)
        guard let scroll else { return }
        // Scroll to the end and back at a steady 1,600 pt/s, one step per display frame.
        let bottom = max(0, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        let top = -scroll.adjustedContentInset.top
        for target in [bottom, top] {
            let from = scroll.contentOffset.y
            let duration = max(0.3, abs(target - from) / 1_600)
            let began = CACurrentMediaTime()
            while true {
                await frames.nextFrame()
                let progress = min(1, (CACurrentMediaTime() - began) / duration)
                scroll.contentOffset.y = from + (target - from) * progress
                if progress >= 1 { break }
            }
        }
        let missed = frames.takeMissed()
        ProfileScenarioLedger.shared.add("sheet.scroll_frames", missed.observed)
        ProfileScenarioLedger.shared.add("sheet.scroll_missed_frames", missed.frames)
        ProfileScenarioLedger.shared.add("sheet.scroll_missed_ms", missed.milliseconds)
        // Close through Done and wait until the sheet is gone.
        guard let presented = host?.presentedViewController,
              let done = ProfileAccessibility.element(in: presented.view, labels: ["Done"]) else {
            throw ProfileScenarioError.workloadDiverged("the sheet has no Done control")
        }
        if let control = done as? UIControl ?? (done as? UIView).flatMap({ profileViews(UIControl.self, in: $0).first }) {
            control.sendActions(for: .touchUpInside)
        } else if !done.accessibilityActivate() {
            print("TRON_PROFILE_DEBUG done=\(type(of: done)) controls=\(profileViews(UIControl.self, in: presented.view).map { "\(type(of: $0)):\($0.accessibilityLabel ?? "-")" })")
        }
        try await profileWaitUntil("the sheet closes", timeout: .seconds(5)) { self.host?.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(300))
    }

    private func sheetScrollView() -> UIScrollView? {
        guard let presented = host?.presentedViewController?.view else { return nil }
        return profileViews(UIScrollView.self, in: presented)
            .filter { $0.bounds.height > 100 }
            .max { $0.contentSize.height < $1.contentSize.height }
    }

    func renderCheck() -> ProfileRenderCheck {
        ProfileRenderCheck(
            counters: ["sheet_cycles": cycles],
            divergence: cycles >= 1 ? nil : "no sheet cycle completed"
        )
    }

    var surface: UIView? { host?.view }

    func teardown() async {
        await fixture.teardown()
        if let savedFilter {
            UserDefaults.standard.set(savedFilter, forKey: DashboardServerFilterPreferences.documentKey)
        } else {
            UserDefaults.standard.removeObject(forKey: DashboardServerFilterPreferences.documentKey)
        }
    }
}

/// Finds SwiftUI controls through the accessibility tree the app already
/// publishes, so a scenario drives the real control without a test hook.
@MainActor
enum ProfileAccessibility {
    /// SwiftUI publishes its accessibility tree only to an accessibility
    /// client. Turn on the automation client XCUITest itself uses, so the
    /// scenario carries the same accessibility cost as a UI test run.
    static func enableAutomation() {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(library, "_AXSSetAutomationEnabled") else { return }
        typealias Setter = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: Setter.self)(1)
    }

    static func element(in root: UIView, labels: Set<String>) -> NSObject? {
        // A hosting view can carry its control's label; prefer SwiftUI's own
        // accessibility node, which is the activatable element.
        var stack: [NSObject] = [root]
        var visited = 0
        var hostMatch: NSObject?
        while let node = stack.popLast(), visited < 20_000 {
            visited += 1
            if let label = node.accessibilityLabel, labels.contains(label) {
                if !(node is UIView) { return node }
                hostMatch = hostMatch ?? node
            }
            if let elements = node.accessibilityElements as? [NSObject] { stack.append(contentsOf: elements) }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count { if let element = node.accessibilityElement(at: index) as? NSObject { stack.append(element) } }
            }
            if let view = node as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return hostMatch
    }
}

/// Display frames the main thread delivered late. A frame interval longer than
/// 1.5 nominal frames counts the frames it skipped.
@MainActor
final class ProfileFrameClock: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var observed = 0
    private var missedFrames = 0
    private var missedSeconds: CFTimeInterval = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func nextFrame() async {
        guard link != nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func takeMissed() -> (frames: Int, milliseconds: Int, observed: Int) {
        defer { observed = 0; missedFrames = 0; missedSeconds = 0 }
        return (missedFrames, Int(missedSeconds * 1_000), observed)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let nominal = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        if let last {
            let interval = link.timestamp - last
            observed += 1
            if interval > nominal * 1.5 {
                missedFrames += Int((interval / nominal).rounded()) - 1
                missedSeconds += interval - nominal
            }
        }
        last = link.timestamp
        let ready = waiters
        waiters = []
        ready.forEach { $0.resume() }
    }
}
