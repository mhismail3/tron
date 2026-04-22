import XCTest
@testable import TronMobile

/// Tests for the pure `NotificationInboxFilter.apply` predicate that drives the
/// "All / Unread" segmented control in `NotificationListSheet`.
///
/// The filter is a static pure function by design: the sheet's visible list is
/// always `apply(store.notifications, filter)`, with no hidden state. These
/// tests cover every branch of the predicate so UI breakage in the picker
/// doesn't silently ship if somebody edits the enum raw values or adds a
/// third case without updating the apply function.
@available(iOS 26.0, *)
final class NotificationInboxFilterTests: XCTestCase {

    // MARK: - Fixtures

    private func makeNotification(
        id: String,
        isRead: Bool
    ) -> NotificationDTO {
        NotificationDTO(
            eventId: id,
            sessionId: "session-\(id)",
            toolCallId: nil,
            timestamp: "2026-01-01T00:00:00Z",
            title: "Title \(id)",
            body: "Body \(id)",
            sheetContent: nil,
            isRead: isRead,
            readAt: isRead ? "2026-01-01T00:01:00Z" : nil,
            sessionTitle: nil,
            isUserSession: true
        )
    }

    // MARK: - .all

    /// `.all` is a passthrough — the predicate must not reorder or drop rows.
    /// The sheet relies on this so the list state order matches the
    /// `NotificationStore.notifications` order exactly.
    func testAllFilterReturnsInputOrderUnchanged() {
        let inputs = [
            makeNotification(id: "a", isRead: false),
            makeNotification(id: "b", isRead: true),
            makeNotification(id: "c", isRead: false)
        ]
        let output = NotificationInboxFilter.apply(inputs, filter: .all)
        XCTAssertEqual(output.map(\.eventId), ["a", "b", "c"])
    }

    func testAllFilterOnEmptyInputReturnsEmpty() {
        let output = NotificationInboxFilter.apply([], filter: .all)
        XCTAssertTrue(output.isEmpty)
    }

    func testAllFilterOnFullyReadReturnsAll() {
        let inputs = [
            makeNotification(id: "a", isRead: true),
            makeNotification(id: "b", isRead: true)
        ]
        let output = NotificationInboxFilter.apply(inputs, filter: .all)
        XCTAssertEqual(output.count, 2)
    }

    // MARK: - .unread

    /// `.unread` drops rows where `isRead == true`. Preserves order so the
    /// filtered list displays newest-first the same way the unfiltered one
    /// does.
    func testUnreadFilterDropsReadNotifications() {
        let inputs = [
            makeNotification(id: "a", isRead: false),
            makeNotification(id: "b", isRead: true),
            makeNotification(id: "c", isRead: false),
            makeNotification(id: "d", isRead: true)
        ]
        let output = NotificationInboxFilter.apply(inputs, filter: .unread)
        XCTAssertEqual(output.map(\.eventId), ["a", "c"])
    }

    func testUnreadFilterOnFullyReadReturnsEmpty() {
        let inputs = [
            makeNotification(id: "a", isRead: true),
            makeNotification(id: "b", isRead: true)
        ]
        let output = NotificationInboxFilter.apply(inputs, filter: .unread)
        XCTAssertTrue(output.isEmpty)
    }

    func testUnreadFilterOnFullyUnreadReturnsAll() {
        let inputs = [
            makeNotification(id: "a", isRead: false),
            makeNotification(id: "b", isRead: false)
        ]
        let output = NotificationInboxFilter.apply(inputs, filter: .unread)
        XCTAssertEqual(output.count, 2)
    }

    func testUnreadFilterOnEmptyInputReturnsEmpty() {
        let output = NotificationInboxFilter.apply([], filter: .unread)
        XCTAssertTrue(output.isEmpty)
    }

    // MARK: - Enum surface

    /// Guards the segmented-control source of truth. If a case is added or
    /// renamed, this test breaks so the `apply` switch and the picker UI are
    /// updated in lockstep.
    func testFilterEnumCases() {
        XCTAssertEqual(NotificationInboxFilter.allCases, [.all, .unread])
        XCTAssertEqual(NotificationInboxFilter.all.label, "All")
        XCTAssertEqual(NotificationInboxFilter.unread.label, "Unread")
    }

    /// Identifiable conformance binds each case to its raw value — the
    /// SwiftUI Picker uses `.tag()` to bind; this asserts the id is stable.
    func testFilterIdStableWithRawValue() {
        XCTAssertEqual(NotificationInboxFilter.all.id, "all")
        XCTAssertEqual(NotificationInboxFilter.unread.id, "unread")
    }
}
