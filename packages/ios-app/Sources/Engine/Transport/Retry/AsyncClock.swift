import Foundation

/// Minimal clock abstraction to make time-based code testable.
///
/// Production uses `SystemAsyncClock` (wraps `Task.sleep`). Tests inject `MockAsyncClock`
/// from the test target, which records sleep durations and allows manual time advancement.
/// An outstanding sleep must cooperate with task cancellation and return promptly by throwing
/// `CancellationError` when cancellation wins its logical race with the requested wake.
protocol AsyncClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct SystemAsyncClock: AsyncClock {
    init() {}

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
