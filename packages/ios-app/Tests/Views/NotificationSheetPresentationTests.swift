import XCTest

/// Source-level presentation guards for notification sheets.
///
/// The presentation helper keeps iPhone detents/backgrounds unchanged while
/// switching iPad floating sheets to compact glass form sizing. These tests
/// prevent the notification inbox/detail sheets from drifting back to the
/// oversized default iPad form.
final class NotificationSheetPresentationTests: XCTestCase {

    func testNotificationListSheetUsesIPadCompactGlassPresentation() throws {
        let content = try source(named: "NotificationListSheet.swift")
        XCTAssertTrue(
            content.contains(".adaptivePresentationDetents([.medium, .large], ipadSizing: .compactForm)"),
            "NotificationListSheet must keep iPad compact/glass sizing without changing iPhone detents"
        )
    }

    func testNotificationDetailSheetUsesIPadCompactGlassPresentation() throws {
        let content = try source(named: "NotificationInboxDetailSheet.swift")
        XCTAssertTrue(
            content.contains(".adaptivePresentationDetents([.medium, .large], ipadSizing: .compactForm)"),
            "NotificationInboxDetailSheet must keep iPad compact/glass sizing without changing iPhone detents"
        )
    }

    func testNotificationListSheetKeepsLiveDeepLinkAutoOpenBinding() throws {
        let listSheet = try source(named: "NotificationListSheet.swift")
        let contentView = try chatSource(named: "ContentView.swift")

        XCTAssertTrue(
            listSheet.contains("@Binding var autoOpenInvocationId: String?"),
            "NotificationListSheet needs a live binding so deep links can target an already-open inbox sheet"
        )
        XCTAssertTrue(
            listSheet.contains(".onChange(of: autoOpenInvocationId)"),
            "NotificationListSheet must react when a notification deep-link target arrives after presentation"
        )
        XCTAssertTrue(
            listSheet.contains(".onChange(of: notificationStore.notifications.map(\\.invocationId))"),
            "NotificationListSheet must retry auto-open after the server notification refresh populates rows"
        )
        XCTAssertTrue(
            contentView.contains("autoOpenInvocationId: $notificationAutoOpenInvocationId"),
            "ContentView must pass the live deep-link target binding into NotificationListSheet"
        )
    }

    private func source(named fileName: String) throws -> String {
        try source(pathComponents: ["Sources", "Views", "Notifications", fileName])
    }

    private func chatSource(named fileName: String) throws -> String {
        try source(pathComponents: ["Sources", "Views", "Chat", fileName])
    }

    private func source(pathComponents: [String]) throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        var url = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
