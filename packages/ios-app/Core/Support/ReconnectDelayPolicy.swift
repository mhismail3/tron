import Foundation
import TronMobileCore

package struct ReconnectDelayPolicy: Sendable {
    package static let standard = ReconnectDelayPolicy(
        initialSeconds: 2,
        multiplier: 1.7,
        maximumSeconds: 15,
        jitterFraction: 0.2,
        nextUnitInterval: { Double.random(in: 0...1) }
    )

    package let initialSeconds: Double
    /// Read by the dashboard pool, which builds its own deterministic curves
    /// from the selected profile's progression.
    package let multiplier: Double
    package let maximumSeconds: Double
    let jitterFraction: Double
    private let nextUnitInterval: @Sendable () -> Double

    package init(
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

    package func delay(nominalSeconds: Double) -> Duration {
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
    package func delay(forFailureAttempt attempt: Int) -> Duration {
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
package final class GatewayReconnectSchedule {
    private let clock: MonotonicClock
    private var delayPolicy: ReconnectDelayPolicy
    private var nominalDelay: Double
    private var pending: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?

    package init(clock: MonotonicClock, delayPolicy: ReconnectDelayPolicy = .standard) {
        self.clock = clock
        self.delayPolicy = delayPolicy
        self.nominalDelay = delayPolicy.initialSeconds
    }

    package func afterFailure() async -> Bool {
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

    package func accelerate() {
        guard continuation != nil else { return }
        pending?.cancel()
        resume(true)
    }

    /// A path change re-routes the next attempt (C-3): cancel the pending wait
    /// so the loop attempts at once, and restart the curve so the new path's
    /// first retry is the base interval rather than the interval the old path's
    /// failures had grown to. Repeated failures on an unchanged path keep the
    /// capped, jittered curve `accelerate()` leaves alone.
    package func restartForPathChange() {
        accelerate()
        nominalDelay = delayPolicy.initialSeconds
    }

    /// Replaces the curve this schedule follows from its next wait on, keeping
    /// the nominal delay already reached. An owner whose curve depends on how
    /// far a run of failures has gone (the dashboard pool escalates after a
    /// few) uses this so the switch neither restarts at the base interval nor
    /// shortens the wait it is in the middle of growing.
    package func adopt(delayPolicy: ReconnectDelayPolicy) {
        self.delayPolicy = delayPolicy
    }

    package func reset() {
        cancelPending(resume: false)
        nominalDelay = delayPolicy.initialSeconds
    }

    package func cancel() {
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
