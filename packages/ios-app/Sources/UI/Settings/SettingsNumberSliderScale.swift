import Foundation

/// Landmarks aid navigation without quantizing a continuous numeric value.
struct SettingsNumberSliderScale {
    let minimum: Int
    let maximum: Int
    let defaultValue: Int

    var detents: [Int] {
        guard maximum > minimum else { return [minimum] }
        let reference = (1_000_000...1_100_000).contains(maximum) ? 1_000_000 : maximum
        let quarter = Double(reference) / 4
        let rounding = pow(10, max(0, floor(log10(max(1, quarter))) - 1))
        let preferred = clamp(defaultValue)
        let baseline = reference == 1_000_000 && preferred > 400_000 ? clamp(200_000) : preferred
        let separation = Double(maximum - minimum) * 0.08
        let quarters = (1...3).map { Int((quarter * Double($0) / rounding).rounded() * rounding) }
            .filter { (minimum...maximum).contains($0) && abs(Double($0 - preferred)) > separation && abs(Double($0 - baseline)) > separation }
        return Set([minimum, maximum, preferred, baseline] + quarters).sorted()
    }

    func clamp(_ value: Int) -> Int { min(maximum, max(minimum, value)) }

    func progress(for value: Int) -> Double {
        guard maximum > minimum else { return 0 }
        return Double(clamp(value) - minimum) / Double(maximum - minimum)
    }

    func value(at progress: Double) -> Int {
        let bounded = min(1, max(0, progress))
        return clamp(minimum + Int((bounded * Double(maximum - minimum)).rounded()))
    }

    func nearestDetent(to progress: Double) -> Int {
        detents.min { abs(self.progress(for: $0) - progress) < abs(self.progress(for: $1) - progress) } ?? minimum
    }

    /// Point-based attraction feels the same on narrow phones and wide sheets.
    func attractedProgress(_ raw: Double, trackWidth: Double) -> Double {
        let bounded = min(1, max(0, raw))
        guard trackWidth > 0 else { return bounded }
        let nearest = nearestDetent(to: bounded)
        let delta = progress(for: nearest) - bounded
        let distance = abs(delta) * trackWidth
        let radius = attractionRadius(for: nearest, trackWidth: trackWidth)
        guard radius > 0, distance < radius else { return bounded }
        return bounded + delta * 0.72 * pow(1 - distance / radius, 2)
    }

    func settledValue(at progress: Double, trackWidth: Double) -> Int {
        let nearest = nearestDetent(to: progress)
        if abs(self.progress(for: nearest) - progress) * max(1, trackWidth)
            <= attractionRadius(for: nearest, trackWidth: max(1, trackWidth)) / 2 { return nearest }
        return value(at: progress)
    }

    private func attractionRadius(for detent: Int, trackWidth: Double) -> Double {
        // Adjacent wells must not overlap, even for a reference near a bound.
        let spacing = detents.filter { $0 != detent }
            .map { abs(progress(for: $0) - progress(for: detent)) * trackWidth }
            .min() ?? 36
        return min(18, spacing / 2)
    }

    func adjacentDetent(to value: Int, increasing: Bool) -> Int {
        if increasing { return detents.first(where: { $0 > value }) ?? maximum }
        return detents.last(where: { $0 < value }) ?? minimum
    }
}
