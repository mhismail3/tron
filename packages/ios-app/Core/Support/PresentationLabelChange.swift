import Foundation

/// Finds the instant a time-dependent label next changes, so a `TimelineView`
/// can render exactly then instead of polling at a fixed cadence.
///
/// Only labels that never return to an earlier value as time advances qualify
/// (relative-time and elapsed-time text). That makes "differs from the label at
/// `start`" monotone in time, so a bounded search finds the first differing
/// instant without sampling every interval. `PresentationLabelChangeTests`
/// verifies that property for the formatters that use it.
package enum PresentationLabelChange {
    /// Returns the earliest representable instant after `start` whose label
    /// differs from the label at `start`. When the label does not change within
    /// `horizon`, returns `start + horizon`, where it is unchanged, so a caller
    /// re-renders harmlessly and searches again instead of missing a change.
    ///
    /// `lattice`, when supplied, is an instant whose whole-second offsets are
    /// the expected change instants. Probing them first keeps the common case to
    /// a few label evaluations; the result is still verified to be exact.
    package static func next(
        after start: Date,
        horizon: TimeInterval,
        lattice: Date? = nil,
        label: (Date) -> String
    ) -> Date {
        let initial = label(start)
        func differs(_ instant: Double) -> Bool {
            label(Date(timeIntervalSinceReferenceDate: instant)) != initial
        }
        let origin = (lattice ?? start).timeIntervalSinceReferenceDate
        var low = start.timeIntervalSinceReferenceDate
        let limit = low + horizon

        // Exponential probe for a changed instant: whole-second offsets after
        // `start`, one, two, four... seconds apart.
        var high = limit
        var offset = (low - origin).rounded(.down) + 1
        var step: Double = 1
        while true {
            let candidate = min(origin + offset, limit)
            if candidate > low {
                if differs(candidate) {
                    high = candidate
                    break
                }
                if candidate >= limit { return Date(timeIntervalSinceReferenceDate: limit) }
                low = candidate
            }
            offset += step
            step *= 2
        }

        // Narrow on whole-second offsets strictly between the bounds.
        while true {
            let middle = (((low - origin) + (high - origin)) / 2).rounded(.down)
            let candidate = origin + middle
            guard candidate > low, candidate < high else { break }
            if differs(candidate) { high = candidate } else { low = candidate }
        }

        // `high` is exact when the representable instant before it still shows
        // the initial label; otherwise bisect to adjacent representable instants.
        let previous = high.nextDown
        if previous <= low || !differs(previous) {
            return Date(timeIntervalSinceReferenceDate: high)
        }
        high = previous
        while true {
            let middle = low + (high - low) / 2
            guard middle > low, middle < high else { break }
            if differs(middle) { high = middle } else { low = middle }
        }
        return Date(timeIntervalSinceReferenceDate: high)
    }
}
