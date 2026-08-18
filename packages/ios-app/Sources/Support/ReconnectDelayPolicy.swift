import Foundation

struct ReconnectDelayPolicy: Sendable {
    static let standard = ReconnectDelayPolicy(
        initialSeconds: 2,
        multiplier: 1.7,
        maximumSeconds: 15,
        jitterFraction: 0.2,
        nextUnitInterval: { Double.random(in: 0...1) }
    )

    let initialSeconds: Double
    let multiplier: Double
    let maximumSeconds: Double
    let jitterFraction: Double
    private let nextUnitInterval: @Sendable () -> Double

    init(
        initialSeconds: Double = 2,
        multiplier: Double = 1.7,
        maximumSeconds: Double = 15,
        jitterFraction: Double = 0.2,
        nextUnitInterval: @escaping @Sendable () -> Double
    ) {
        precondition(initialSeconds.isFinite && initialSeconds > 0)
        precondition(multiplier.isFinite && multiplier >= 1)
        precondition(maximumSeconds.isFinite && maximumSeconds >= initialSeconds)
        precondition(jitterFraction.isFinite && (0...1).contains(jitterFraction))
        self.initialSeconds = initialSeconds
        self.multiplier = multiplier
        self.maximumSeconds = maximumSeconds
        self.jitterFraction = jitterFraction
        self.nextUnitInterval = nextUnitInterval
    }

    func delay(nominalSeconds: Double) -> Duration {
        let nominal = min(max(nominalSeconds, 0), maximumSeconds)
        let lower = nominal * (1 - jitterFraction)
        let upper = min(nominal * (1 + jitterFraction), maximumSeconds)
        let sample = nextUnitInterval()
        let unit = sample.isFinite ? min(max(sample, 0), 1) : 0.5
        return .seconds(lower + ((upper - lower) * unit))
    }

    func nextNominalSeconds(after current: Double) -> Double {
        min(current * multiplier, maximumSeconds)
    }
}
