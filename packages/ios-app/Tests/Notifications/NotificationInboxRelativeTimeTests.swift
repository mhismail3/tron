import Foundation
import Testing
@testable import TronMobile

/// Failure mode: the inbox's shared formatter differs from the new default
/// `RelativeDateTimeFormatter` each row used to create on every tick (units
/// style, date-time style, context or locale), so row text changes.
@MainActor
@Suite("Notification inbox relative time")
struct NotificationInboxRelativeTimeTests {
    @Test("the shared formatter's text is identical to a new default formatter's")
    func matchesNewFormatter() {
        let reference = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
        var offsets: [TimeInterval] = [0, 0.5, -0.5, 1, -1, 59.9, 60, 3_599, 3_600, 86_399, 86_400]
        let scales: [TimeInterval] = [1, 60, 3_600, 86_400, 604_800, 2_592_000, 31_536_000]
        for scale in scales {
            for multiple in stride(from: 1.0, through: 13, by: 1.5) {
                offsets.append(contentsOf: [scale * multiple, -scale * multiple])
            }
        }
        for offset in offsets {
            let date = reference.addingTimeInterval(-offset)
            #expect(
                NotificationInboxRelativeTime.string(for: date, relativeTo: reference)
                    == RelativeDateTimeFormatter().localizedString(for: date, relativeTo: reference)
            )
        }
    }
}
