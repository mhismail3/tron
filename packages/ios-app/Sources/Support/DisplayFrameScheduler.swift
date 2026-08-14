import QuartzCore

struct DisplayFrameScheduler: Sendable {
    private let waitForFrame: @MainActor @Sendable () async throws -> Void

    init(waitForFrame: @escaping @MainActor @Sendable () async throws -> Void) {
        self.waitForFrame = waitForFrame
    }

    @MainActor
    func nextFrame() async throws {
        try await waitForFrame()
    }

    static let displayLink = DisplayFrameScheduler {
        try Task.checkCancellation()
        let waiter = DisplayFrameWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.start(continuation)
            }
        } onCancel: {
            Task { @MainActor in waiter.cancel() }
        }
    }
}

@MainActor
final class DisplayFrameWaiter: NSObject {
    private var continuation: CheckedContinuation<Void, Error>?
    private var displayLink: CADisplayLink?

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let displayLink = CADisplayLink(target: self, selector: #selector(framePresented))
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    var isWaiting: Bool { continuation != nil }

    func cancel() {
        finish(throwing: CancellationError())
    }

    @objc func framePresented() {
        finish(throwing: nil)
    }

    private func finish(throwing error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        displayLink?.invalidate()
        displayLink = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}
