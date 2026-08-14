import CoreGraphics

@MainActor
final class ChatPerformanceTracker {
    private let signposts: any PerformanceSignposting
    private var scrollInterval: PerformanceInterval?
    private var prependGeneration = 0
    private var prependInterval: (generation: Int, interval: PerformanceInterval)?

    init(signposts: any PerformanceSignposting) {
        self.signposts = signposts
    }

    func beginScrollCommand() {
        endScroll(result: .discarded)
        scrollInterval = signposts.begin(.scrollCommandSettle)
    }

    func settleScroll() {
        endScroll(result: .success)
    }

    func discardScroll() {
        endScroll(result: .discarded)
    }

    func beginPrepend() -> Int {
        if let prependInterval {
            signposts.end(prependInterval.interval, result: .discarded, metrics: .none)
        }
        prependGeneration &+= 1
        prependInterval = (
            generation: prependGeneration,
            interval: signposts.begin(.prependSettle)
        )
        return prependGeneration
    }

    func endPrepend(generation: Int, result: PerformanceResult) {
        guard let prependInterval, prependInterval.generation == generation else { return }
        self.prependInterval = nil
        signposts.end(prependInterval.interval, result: result, metrics: .none)
    }

    func cancelAll() {
        endScroll(result: .cancelled)
        if let prependInterval {
            self.prependInterval = nil
            signposts.end(prependInterval.interval, result: .cancelled, metrics: .none)
        }
    }

    private func endScroll(result: PerformanceResult) {
        guard let scrollInterval else { return }
        self.scrollInterval = nil
        signposts.end(scrollInterval, result: result, metrics: .none)
    }
}

@MainActor
enum ChatPrependSettlement {
    static func result(
        after scheduler: DisplayFrameScheduler,
        requestedOffsetY: CGFloat,
        isCurrent: () -> Bool,
        observedOffsetY: () -> CGFloat
    ) async -> PerformanceResult {
        do {
            try await scheduler.nextFrame()
        } catch {
            return PerformanceResult.forFailure(error)
        }
        guard !Task.isCancelled, isCurrent() else {
            return Task.isCancelled ? .cancelled : .discarded
        }
        return abs(observedOffsetY() - requestedOffsetY) <= 1 ? .success : .failure
    }
}

@MainActor
final class ChatPagingOwner {
    private(set) var generation = 0
    private var task: Task<Void, Never>?
    var hasTask: Bool { task != nil }

    func begin() -> Int {
        cancel()
        return generation
    }

    func install(_ task: Task<Void, Never>, generation: Int) {
        guard self.generation == generation else {
            task.cancel()
            return
        }
        self.task = task
    }

    func finish(generation: Int) -> Bool {
        guard self.generation == generation else { return false }
        task = nil
        return true
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
