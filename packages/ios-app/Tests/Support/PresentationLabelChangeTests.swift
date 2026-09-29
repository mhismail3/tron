import Foundation
import SwiftUI
import Testing
@testable import TronMobileCore
@testable import TronMobile

/// Failure modes these tests target (a dashboard row re-renders only at the
/// instants `DashboardActivityClock` yields):
/// 1. A yielded instant comes after a label change, so the row shows a stale
///    label, or before it, so the change is skipped until the next entry.
/// 2. The search skips a change entirely (a label that returns to an earlier
///    value would do this, so that property is checked per locale).
/// 3. Future-dated, fractional or malformed timestamps break the search.
/// 4. A settled row still re-renders on a fixed cadence.
@Suite("Presentation label change schedules")
struct PresentationLabelChangeTests {
    private static let base = Date(timeIntervalSinceReferenceDate: 812_345_678.25)

    /// Row ages at mount, including future-dated and fractional timestamps.
    private static let offsets: [TimeInterval] = [
        0, 0.4, 0.999, 1, 30.5, 59.2, 3_599.7, 3_600, 7_200, 86_399.5, 86_400 * 2.5,
        86_400 * 6.9, 86_400 * 30, 86_400 * 364.5, -0.3, -1, -59.5, -3_600.5, -86_400 * 3.2,
    ]

    @Test("dashboard labels equal the formatter at every sampled instant and never skip a change")
    func dashboardClockMatchesFormatter() throws {
        for offset in Self.offsets {
            let updatedAt = Self.base.addingTimeInterval(-offset)
            let clock = DashboardActivityClock(updatedAt: GatewayTimestamp.preciseString(from: updatedAt))
            let parsed = try #require(clock.updatedAt)
            try Self.verifySchedule(
                entries: clock.entries(from: Self.base, mode: .normal),
                start: Self.base,
                end: Self.base.addingTimeInterval(4 * 86_400),
                anchor: parsed,
                label: clock.label(relativeTo:),
                oracle: { GatewayTimestamp.relativeDescription(parsed, relativeTo: $0) }
            )
        }
    }

    @Test("malformed timestamps render once with today's empty label")
    func malformedTimestamp() {
        let clock = DashboardActivityClock(updatedAt: "not-a-timestamp")
        #expect(clock.label(relativeTo: Self.base) == "")
        #expect(Array(clock.entries(from: Self.base, mode: .normal)) == [Self.base])
    }

    @Test("a settled two-hour-old row no longer re-renders every second")
    func settledRowTickCounts() {
        let clock = DashboardActivityClock(
            updatedAt: GatewayTimestamp.preciseString(from: Self.base.addingTimeInterval(-7_200))
        )
        let perMinute = Self.entries(clock.entries(from: Self.base, mode: .normal), through: Self.base.addingTimeInterval(60))
        let perHour = Self.entries(clock.entries(from: Self.base, mode: .normal), through: Self.base.addingTimeInterval(3_600))
        // Only the mount render; the fixed one-second clock rendered 60 and 3,600 times.
        #expect(perMinute.count == 1)
        #expect(perHour.count == 2)

        let fresh = DashboardActivityClock(updatedAt: GatewayTimestamp.preciseString(from: Self.base))
        let firstDay = Self.entries(fresh.entries(from: Self.base, mode: .normal), through: Self.base.addingTimeInterval(86_400))
        #expect(firstDay.count < 150)
    }

    /// The search relies on labels never returning to an earlier value; this
    /// checks the property and the resulting schedule for other locales, time
    /// zones (half-hour offsets and daylight-saving transitions) and styles.
    @Test("relative labels never repeat and schedules stay exact across locales and time zones")
    func localesAndTimeZones() throws {
        let configurations: [(String, String, RelativeDateTimeFormatter.UnitsStyle)] = [
            ("en_US", "America/Los_Angeles", .abbreviated),
            ("fr_FR", "Europe/Paris", .full),
            ("de_DE", "Australia/Lord_Howe", .abbreviated),
            ("ja_JP", "Asia/Tokyo", .short),
            ("ar_EG", "Asia/Kolkata", .full),
            ("ru_RU", "Europe/Moscow", .abbreviated),
            ("he_IL", "Pacific/Chatham", .spellOut),
            ("zh_Hans_CN", "America/Sao_Paulo", .full),
        ]
        // Half a day before the 2026-03-08 and 2026-11-01 US daylight-saving
        // transitions, so each three-day window crosses one.
        let transitions = [
            Date(timeIntervalSince1970: 1_772_964_000 - 43_200),
            Date(timeIntervalSince1970: 1_793_523_600 - 43_200),
        ]
        for (index, (localeID, zoneID, style)) in configurations.enumerated() {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = style
            formatter.locale = Locale(identifier: localeID)
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = formatter.locale
            calendar.timeZone = try #require(TimeZone(identifier: zoneID))
            formatter.calendar = calendar
            for mount in [Self.base, transitions[index % transitions.count]] {
                for offset in [42.5, -95.5, 86_400 * 1.5, 86_400 * 27.5] {
                    let updatedAt = mount.addingTimeInterval(-offset)
                    let label = { (reference: Date) in formatter.localizedString(for: updatedAt, relativeTo: reference) }
                    try Self.verifyNeverRepeats(label: label, from: mount, through: mount.addingTimeInterval(3 * 86_400))
                    try Self.verifySchedule(
                        entries: Self.searchEntries(from: mount, anchor: updatedAt, label: label),
                        start: mount,
                        end: mount.addingTimeInterval(3 * 86_400),
                        anchor: updatedAt,
                        label: label,
                        oracle: label
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private static func entries<S: Sequence>(_ sequence: S, through end: Date) -> [Date] where S.Element == Date {
        var result: [Date] = []
        for entry in sequence {
            if entry > end { break }
            result.append(entry)
        }
        return result
    }

    /// The dashboard's production iteration with an injected label.
    private static func searchEntries(from start: Date, anchor: Date, label: @escaping (Date) -> String) -> AnySequence<Date> {
        AnySequence { () -> AnyIterator<Date> in
            var previous: Date?
            return AnyIterator {
                guard let last = previous else {
                    previous = start
                    return start
                }
                let change = PresentationLabelChange.next(
                    after: last,
                    horizon: DashboardActivityClock.changeSearchHorizon,
                    lattice: anchor,
                    label: label
                )
                previous = change
                return change
            }
        }
    }

    /// Simulates a `TimelineView` that renders at each entry. The label shown
    /// at an instant is the one rendered at the latest entry at or before it;
    /// it must equal the formatter at that instant, so it is never staler than
    /// the entry cadence and never fresher than the truth.
    private static func verifySchedule<S: Sequence>(
        entries sequence: S,
        start: Date,
        end: Date,
        anchor: Date,
        label: (Date) -> String,
        oracle: (Date) -> String
    ) throws where S.Element == Date {
        let entries = Self.entries(sequence, through: end)
        try #require(entries.first == start)
        for (index, entry) in entries.enumerated().dropFirst() {
            let previous = entries[index - 1]
            #expect(entry > previous)
            // Exact: the instant before the entry still shows the previous
            // render, and the entry shows a new label unless it is a horizon
            // re-render.
            #expect(oracle(entry.nextDownInstant) == label(previous), "stale entry at \(entry)")
            if entry.timeIntervalSince(previous) < DashboardActivityClock.changeSearchHorizon {
                #expect(oracle(entry) != label(previous), "entry without a change at \(entry)")
            }
        }
        var samples: [Date] = []
        var generator = SplitMix64(seed: UInt64(bitPattern: Int64(anchor.timeIntervalSinceReferenceDate * 1_000)))
        let span = end.timeIntervalSince(start)
        for _ in 0..<300 {
            samples.append(start.addingTimeInterval(Double(generator.next() % 1_000_000) / 1_000_000 * span))
        }
        for second in stride(from: 0.0, through: 150, by: 0.5) {
            samples.append(start.addingTimeInterval(second))
        }
        let firstLattice = (start.timeIntervalSince(anchor)).rounded(.up)
        for second in stride(from: firstLattice, through: firstLattice + 150, by: 1) {
            let lattice = anchor.addingTimeInterval(second)
            samples.append(contentsOf: [lattice, lattice.nextDownInstant, lattice.addingTimeInterval(0.001)])
        }
        for entry in entries {
            samples.append(contentsOf: [entry, entry.addingTimeInterval(0.000_5), entry.addingTimeInterval(-0.000_5)])
        }
        for sample in samples where sample >= start && sample <= end {
            let rendered = entries.last { $0 <= sample }!
            #expect(label(rendered) == oracle(sample), "label at \(sample) rendered at \(rendered)")
        }
    }

    /// Samples finely where labels count seconds and minutes and coarsely where
    /// they count hours and days, so each distinct label is observed.
    private static func verifyNeverRepeats(label: (Date) -> String, from start: Date, through end: Date) throws {
        var observed: [String] = []
        var instant = start
        while instant <= end {
            let value = label(instant)
            if observed.last != value {
                #expect(!observed.contains(value), "\(value) reappeared at \(instant)")
                observed.append(value)
            }
            let elapsed = instant.timeIntervalSince(start)
            instant = instant.addingTimeInterval(elapsed < 180 ? 0.5 : elapsed < 7_200 ? 20 : 600)
        }
        // Every window crosses at least one unit boundary.
        try #require(observed.count >= 2)
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private extension Date {
    var nextDownInstant: Date { Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.nextDown) }
}
