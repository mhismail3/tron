import Foundation
import Observation

extension ChatViewModel {
    /// Reusable observation loop: watches a value via `withObservationTracking`
    /// and invokes `onChange` each time it changes. Cancelled via the returned task.
    static func observeLoop<T: Equatable>(
        _ read: @escaping @MainActor () -> T,
        onChange: @escaping @MainActor (T) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            var lastValue = read()
            while !Task.isCancelled {
                await waitForObservationChange(read)
                guard !Task.isCancelled else { return }
                let nextValue = read()
                guard nextValue != lastValue else { continue }
                lastValue = nextValue
                onChange(nextValue)
            }
        }
    }

    /// Waits for a single Swift Observation edge and resumes on task
    /// cancellation as well as on value change. Plain `withCheckedContinuation`
    /// leaks if the owning chat view model deinitializes while the observer is
    /// idle, which can happen during session switches, foreground reconnects,
    /// and tests that tear down a mounted chat without another state change.
    @MainActor
    private static func waitForObservationChange<T>(
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
}

private final class ObservationContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        var shouldResume = false
        lock.lock()
        if isFinished {
            shouldResume = true
        } else {
            self.continuation = continuation
        }
        lock.unlock()

        if shouldResume {
            continuation.resume()
        }
    }

    func resume() {
        let continuation = finish()
        continuation?.resume()
    }

    func cancel() {
        let continuation = finish()
        continuation?.resume()
    }

    private func finish() -> CheckedContinuation<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return nil }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}
