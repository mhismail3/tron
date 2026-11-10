import Foundation

package enum PresentationLabelChange {
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

        while true {
            let middle = (((low - origin) + (high - origin)) / 2).rounded(.down)
            let candidate = origin + middle
            guard candidate > low, candidate < high else { break }
            if differs(candidate) { high = candidate } else { low = candidate }
        }

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
