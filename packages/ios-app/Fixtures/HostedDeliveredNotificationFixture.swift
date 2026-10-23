#if HOSTED_TEST
import Observation
import SwiftUI
@preconcurrency import UserNotifications

/// Native Notification Center is real; only delivery is local rather than APNs.
/// Provisional permission belongs to the disposable simulator test host and
/// presents no OS permission dialog. Exact fixture request IDs own cleanup.
@MainActor @Observable
final class HostedDeliveredNotificationFixture: NSObject, UNUserNotificationCenterDelegate {
    var summary = "starting"
    var badge = -1
    private let prefix = "read-fixture-\(UUID().uuidString)-"
    private var names = ["ordinary", "other-chat", "other-machine", "home", "sealed-home", "unrouted"]
    private let center = UNUserNotificationCenter.current()

    func prepare() async throws {
        center.delegate = self
        guard try await center.requestAuthorization(options: [.alert, .provisional]) else {
            throw CocoaError(.userCancelled)
        }
        try await center.setBadgeCount(7)
        try await deliver("ordinary", session: "ordinary-session")
        try await deliver("other-chat", session: "chat-recent-unread")
        try await deliver("other-machine", session: "ordinary-session", machine: "other-machine")
        try await deliver("home", session: "home-session")
        try await deliver("sealed-home", session: "home-chapter-sealed")
        try await deliver("unrouted", session: "ordinary-session", machine: nil)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let rows = await center.deliveredNotifications()
            if rows.filter({ $0.request.identifier.hasPrefix(prefix) }).count == names.count {
                await inspect()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    func inspect() async {
        let rows = await center.deliveredNotifications()
        badge = UIApplication.shared.applicationIconBadgeNumber
        summary = rows.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }.sorted().joined(separator: ",")
    }

    func later(home: Bool) async throws {
        names.append("later")
        try await deliver("later", session: home ? "home-session" : "ordinary-session")
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if await center.deliveredNotifications().contains(where: { $0.request.identifier == prefix + "later" }) {
                await inspect()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    func cleanup() {
        let ids = names.map { prefix + $0 }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        summary = "cleaned"
    }

    private func deliver(_ name: String, session: String, machine: String? = "home-shell-fixture") async throws {
        let content = UNMutableNotificationContent()
        content.title = "Synthetic delivery"
        content.body = name
        content.userInfo = ["sessionId": session]
        if let machine { content.userInfo["machineId"] = machine }
        try await center.add(UNNotificationRequest(identifier: prefix + name, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.list] }
}

struct HostedDeliveredNotificationControls: View {
    let fixture: HostedDeliveredNotificationFixture
    let home: Bool

    var body: some View {
        VStack {
            Text(fixture.summary).accessibilityIdentifier("fixture.delivered-notifications")
            Text("badge:\(fixture.badge)").accessibilityIdentifier("fixture.delivered-badge")
            HStack {
                Button("Inspect delivered") { Task { await fixture.inspect() } }
                Button("Deliver later") { Task { try? await fixture.later(home: home) } }
                Button("Clean delivered") { fixture.cleanup() }
            }
        }.font(.caption2).padding(4).background(.background)
        .task {
            // Native removal is asynchronous and has no completion callback.
            // Observe the real center for the lifetime of the hosted probe.
            while !Task.isCancelled {
                await fixture.inspect()
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { break }
            }
        }
    }
}
#endif
