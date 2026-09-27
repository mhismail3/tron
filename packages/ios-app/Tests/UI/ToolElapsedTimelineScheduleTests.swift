import Foundation
import SwiftUI
import Testing
@testable import TronMobile

/// Failure modes these tests target (a running tool timer re-renders only at
/// the instants `ToolElapsedTimelineSchedule` yields):
/// 1. The sub-minute cadence or phase moves, so a different sequence of tenths
///    is shown than the historical `.periodic(from: .now, by:)` clock showed.
/// 2. The switch out of tenths at one minute shows a string the periodic clock
///    would not have (for example an extra "60.0s").
/// 3. After a minute a whole-second (after an hour, whole-minute) change is
///    skipped or shown late because the uptime-to-date mapping is wrong.
/// 4. Timers keep rendering ten times a second after the label drops to whole
///    seconds.
@Suite("Tool elapsed timeline schedule")
struct ToolElapsedTimelineScheduleTests {
    private static let anchorDate = Date(timeIntervalSinceReferenceDate: 812_345_678.123_4)
    private static let anchorUptime: TimeInterval = 5_432.109_8
    private static let runLength: TimeInterval = 2 * 3_600 + 90

    private struct Scenario {
        let name: String
        let interval: TimeInterval
        /// Displayed milliseconds for a render at a date and uptime.
        let milliseconds: @Sendable (Date, TimeInterval) -> Int?
    }

    private static var scenarios: [Scenario] {
        let clock = ToolElapsedClock(baselineMilliseconds: 237, baselineUptime: anchorUptime - 0.004)
        let lateClock = ToolElapsedClock(baselineMilliseconds: 59_120, baselineUptime: anchorUptime)
        let hourClock = ToolElapsedClock(baselineMilliseconds: 3_598_400, baselineUptime: anchorUptime + 0.2)
        let started = anchorDate.addingTimeInterval(-12.345_6)
        return [
            // ToolElapsedText and ToolRunElapsedText: local uptime clocks at 0.1 s.
            Scenario(name: "local clock", interval: 0.1) { _, uptime in clock.milliseconds(at: uptime) },
            Scenario(name: "near a minute", interval: 0.1) { _, uptime in lateClock.milliseconds(at: uptime) },
            Scenario(name: "near an hour", interval: 0.1) { _, uptime in hourClock.milliseconds(at: uptime) },
            // A run summing two live tools advances twice as fast.
            Scenario(name: "two running tools", interval: 0.1) { _, uptime in
                clock.milliseconds(at: uptime) + lateClock.milliseconds(at: uptime)
            },
            // ToolStatusChip at 0.5 s.
            Scenario(name: "status chip", interval: 0.5) { _, uptime in clock.milliseconds(at: uptime) },
            // DisplayToolElapsedText at 1 s from a wall-clock start timestamp.
            Scenario(name: "display from start timestamp", interval: 1) { date, _ in
                ToolTiming.milliseconds(from: started, to: date)
            },
        ]
    }

    @Test("displayed strings match the periodic clock, sub-minute renders are identical, and later renders are exact")
    func matchesPeriodicClock() throws {
        for scenario in Self.scenarios {
            for latency in [0.0, 0.003, 0.019] {
                let schedule = ToolElapsedTimelineSchedule(
                    anchorDate: Self.anchorDate,
                    anchorUptime: Self.anchorUptime,
                    interval: scenario.interval,
                    milliseconds: scenario.milliseconds
                )
                let end = Self.anchorDate.addingTimeInterval(Self.runLength)
                let today = Self.renders(
                    PeriodicTimelineSchedule(from: Self.anchorDate, by: scenario.interval)
                        .entries(from: Self.anchorDate, mode: .normal),
                    through: end, latency: latency, scenario: scenario
                )
                let scheduled = Self.renders(
                    schedule.entries(from: Self.anchorDate, mode: .normal),
                    through: end, latency: latency, scenario: scenario
                )

                // Every sub-minute render is the periodic clock's render.
                let todaySubMinute = today.prefix { Self.value(of: $0, scenario) < 60_000 }
                #expect(Array(scheduled.prefix(todaySubMinute.count + 1).map(\.date))
                    == Array(today.prefix(todaySubMinute.count + 1).map(\.date)), "\(scenario.name)")
                #expect(Self.distinct(scheduled.map(\.text)) == Self.distinct(today.map(\.text)), "\(scenario.name) latency \(latency)")

                // After the first periodic tick at a minute, each change renders
                // when the elapsed value reaches it, never later.
                let transition = try #require(scheduled.firstIndex { Self.value(of: $0, scenario) >= 60_000 })
                for (index, render) in scheduled.enumerated().dropFirst(transition + 1) {
                    let previous = scheduled[index - 1]
                    let before = render.date.addingTimeInterval(-0.000_001)
                    #expect(schedule.label(renderedAt: before) == schedule.label(renderedAt: previous.date), "\(scenario.name) late at \(render.date)")
                    #expect(schedule.label(renderedAt: render.date) != schedule.label(renderedAt: previous.date), "\(scenario.name) early at \(render.date)")
                }
            }
        }
    }

    @Test("renders drop from ten a second to once per second after a minute and once per minute after an hour")
    func tickCounts() {
        let clock = ToolElapsedClock(baselineMilliseconds: 0, baselineUptime: Self.anchorUptime)
        let schedule = ToolElapsedTimelineSchedule(
            anchorDate: Self.anchorDate,
            anchorUptime: Self.anchorUptime,
            interval: 0.1
        ) { _, uptime in clock.milliseconds(at: uptime) }
        let dates = Self.dates(schedule.entries(from: Self.anchorDate, mode: .normal), through: Self.anchorDate.addingTimeInterval(Self.runLength))
        func count(_ from: TimeInterval, _ to: TimeInterval) -> Int {
            dates.filter { $0.timeIntervalSince(Self.anchorDate) >= from && $0.timeIntervalSince(Self.anchorDate) < to }.count
        }
        #expect(count(0, 59.95) == 600)
        #expect(count(120, 180) == 60)
        #expect(count(3_660, 3_720) == 1)
        #expect(count(3_720, 7_200) == 58)
    }

    // MARK: - Helpers

    private struct Render {
        let date: Date
        let text: String
    }

    /// A `TimelineView` render at each entry; the view reads live clocks
    /// `latency` after the entry fires.
    private static func renders<S: Sequence>(
        _ entries: S,
        through end: Date,
        latency: TimeInterval,
        scenario: Scenario
    ) -> [Render] where S.Element == Date {
        dates(entries, through: end).map { date in
            let rendered = date.addingTimeInterval(latency)
            let uptime = anchorUptime + rendered.timeIntervalSince(anchorDate)
            let text = scenario.milliseconds(rendered, uptime).map(ToolTiming.format(milliseconds:)) ?? ""
            return Render(date: date, text: text)
        }
    }

    private static func value(of render: Render, _ scenario: Scenario) -> Int {
        scenario.milliseconds(render.date, anchorUptime + render.date.timeIntervalSince(anchorDate)) ?? 0
    }

    private static func dates<S: Sequence>(_ entries: S, through end: Date) -> [Date] where S.Element == Date {
        var result: [Date] = []
        for entry in entries {
            if entry > end { break }
            result.append(entry)
        }
        return result
    }

    private static func distinct(_ texts: [String]) -> [String] {
        texts.reduce(into: []) { result, text in
            if result.last != text { result.append(text) }
        }
    }
}
