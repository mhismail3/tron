import Foundation
import Observation

/// Waits for one Swift Observation edge or task cancellation.
///
/// Observation callbacks do not provide cancellation themselves. Stored owner
/// tasks use this bridge so teardown can end an otherwise idle continuation.
@MainActor
func waitForObservationChange<T>(
    _ read: @escaping @MainActor () -> T
) async {
    let box = ObservationContinuationBox()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            box.install(continuation)
            withObservationTracking {
                _ = read()
            } onChange: {
                box.resume()
            }
        }
    } onCancel: {
        box.cancel()
    }
}

private final class ObservationContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let shouldResume = lock.withLock {
            if isFinished { return true }
            self.continuation = continuation
            return false
        }
        if shouldResume { continuation.resume() }
    }

    func resume() {
        finish()?.resume()
    }

    func cancel() {
        finish()?.resume()
    }

    private func finish() -> CheckedContinuation<Void, Never>? {
        lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            defer { continuation = nil }
            return continuation
        }
    }
}
