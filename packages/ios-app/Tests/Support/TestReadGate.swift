import Foundation

/// A deliberately cancellation-insensitive read boundary. Tests must release it
/// and await their owned operation on every outcome, including failed entry waits.
actor TestReadGate {
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { self.continuations.append(continuation) }
            entered.continuation.yield(())
        }
    }

    func waitForEntry() async throws {
        let stream = entered.stream
        try await withTestWatchdog(timeout: .seconds(3)) {
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
        entered.continuation.finish()
    }
}
