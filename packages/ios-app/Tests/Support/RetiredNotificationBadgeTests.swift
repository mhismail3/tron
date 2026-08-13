import Testing
@testable import TronMobile

@MainActor
struct RetiredNotificationBadgeTests {
    @Test("retired notification badge is reset without restoring push registration")
    func clearsBadge() async {
        var requestedCounts: [Int] = []

        await RetiredNotificationBadge.clear { count in
            requestedCounts.append(count)
        }

        #expect(requestedCounts == [0])
    }

    @Test("badge cleanup cannot block app startup")
    func ignoresSystemFailure() async {
        await RetiredNotificationBadge.clear { _ in
            throw BadgeFailure.unavailable
        }
    }

    private enum BadgeFailure: Error {
        case unavailable
    }
}
