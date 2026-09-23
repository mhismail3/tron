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

    /// Reuses the connection backoff curve without taking ownership of a caller's retry budget.
    func delay(forFailureAttempt attempt: Int) -> Duration {
        var nominal = initialSeconds
        for _ in 1..<max(1, attempt) {
            guard nominal < maximumSeconds else { break }
            nominal = nextNominalSeconds(after: nominal)
        }
        return delay(nominalSeconds: nominal)
    }
}

/// Owns the one pending reconnect delay for one connection executor.
@MainActor
final class GatewayReconnectSchedule {
    private let clock: MonotonicClock
    private let delayPolicy: ReconnectDelayPolicy
    private var nominalDelay: Double
    private var pending: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(clock: MonotonicClock, delayPolicy: ReconnectDelayPolicy = .standard) {
        self.clock = clock
        self.delayPolicy = delayPolicy
        self.nominalDelay = delayPolicy.initialSeconds
    }

    func afterFailure() async -> Bool {
        cancelPending(resume: false)
        let delay = delayPolicy.delay(nominalSeconds: nominalDelay)
        nominalDelay = delayPolicy.nextNominalSeconds(after: nominalDelay)
        let clock = self.clock
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.pending = Task { @MainActor [weak self] in
                    do { try await clock.sleep(delay) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.resume(true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func accelerate() {
        guard continuation != nil else { return }
        pending?.cancel()
        resume(true)
    }

    func reset() {
        cancelPending(resume: false)
        nominalDelay = delayPolicy.initialSeconds
    }

    func cancel() {
        cancelPending(resume: false)
    }

    private func resume(_ result: Bool) {
        let continuation = self.continuation
        self.continuation = nil
        pending = nil
        continuation?.resume(returning: result)
    }

    private func cancelPending(resume result: Bool) {
        pending?.cancel()
        pending = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        }
    }
}
