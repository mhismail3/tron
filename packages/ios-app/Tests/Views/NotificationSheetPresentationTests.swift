import XCTest

/// Source-level presentation guards for notification sheets.
///
/// The presentation helper keeps iPhone detents/backgrounds unchanged while
/// switching iPad floating sheets to balanced glass form sizing. These tests
/// prevent the notification inbox/detail sheets and shared presentation helper
/// from drifting back to narrow, oversized iPad forms.
final class NotificationSheetPresentationTests: XCTestCase {

    func testAdaptivePresentationUsesBalancedIPadSizingWithoutChangingPhoneBranch() throws {
        let content = try extensionSource(named: "View+Extensions.swift")

        XCTAssertTrue(
            content.contains("struct BalancedLargeFormSizing"),
            "Detail-heavy iPad sheets need a dedicated balanced sizing primitive"
        )
        XCTAssertTrue(
            content.contains("width: min(referenceWidth * 0.46, 540)"),
            "Large iPad sheets should avoid becoming too wide in landscape"
        )
        XCTAssertTrue(
            content.contains("let maxHeight = min(referenceHeight * 0.88, 900)"),
            "Large iPad sheets should cap height without becoming an empty full-height column"
        )
        XCTAssertTrue(
            content.contains("minHeight: min(540, maxHeight)"),
            "Large iPad sheets should keep a usable floor for settings content"
        )
        XCTAssertTrue(
            content.contains("width: min(referenceWidth * 0.40, 470)"),
            "Compact iPad sheets should avoid becoming over-wide"
        )
        XCTAssertTrue(
            content.contains("let maxHeight = min(referenceHeight * 0.78, 760)"),
            "Compact iPad sheets should avoid becoming oddly tall for short detail content"
        )
        XCTAssertTrue(
            content.contains("minHeight: min(420, maxHeight)"),
            "Compact iPad sheets should keep a usable floor for card rows"
        )
        XCTAssertTrue(
            content.contains("AdaptiveSheetMetrics.balancedLargeFormSize"),
            "The iPad content frame should reuse the same large-form sizing helper"
        )
        XCTAssertTrue(
            content.contains("AdaptiveSheetMetrics.compactFormSize"),
            "The iPad content frame should reuse the same compact sizing helper"
        )
        XCTAssertTrue(
            content.contains(".presentationContentInteraction(.scrolls)"),
            "iPad floating sheets should prioritize scrolling long settings content in landscape"
        )
        XCTAssertTrue(
            content.contains("content\n                .presentationContentInteraction(.scrolls)"),
            "The iPad branch should size a true floating form instead of inheriting phone detents"
        )
        XCTAssertTrue(
            content.contains(".frame(width: targetSize.width)\n                .frame(maxHeight: targetSize.height)"),
            "iPad floating sheets should cap height while allowing short content to shrink"
        )
        XCTAssertTrue(
            content.contains(".presentationSizing(.balancedLargeForm)"),
            "The iPad large-form branch must use the balanced iPad sizing primitive"
        )
        XCTAssertTrue(
            content.contains("needsOpaquePhoneBackground ? Color.tronBackground : .clear"),
            "The non-iPad branch should keep its existing background behavior"
        )
        XCTAssertTrue(
            content.contains("let detented = content.presentationDetents(detents, selection: phoneSelection)"),
            "Phone presentation detents must remain on the non-iPad branch"
        )
        XCTAssertTrue(
            content.contains("case .unchanged:\n            phoneBackgroundBody(content: detented)"),
            "Sheets converted from raw detents need to preserve their existing phone sizing"
        )
    }

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

    private func extensionSource(named fileName: String) throws -> String {
        try source(pathComponents: ["Sources", "Extensions", fileName])
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
