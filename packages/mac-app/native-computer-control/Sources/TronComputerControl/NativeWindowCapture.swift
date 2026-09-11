import Foundation

package enum NativeWindowCaptureError: Error, Sendable, Equatable {
    case invalidLimits, permissionUnavailable, processUnavailable, sourceUnavailable
    case unsupportedSystem, malformedFrame, encodingFailed, streamFailed, stopFailed, stopped
}

/// Producer bounds, deliberately no larger than the browser viewer's admission.
package struct NativeWindowCaptureLimits: Sendable, Equatable {
    package let width: Int
    package let height: Int
    package let framesPerSecond: Int
    static let queueDepth = 3
    static let maximumEncodedBytes = 2 * 1_024 * 1_024
    static let maximumRawBytes = 8 * 1_024 * 1_024

    package init(width: Int = 1280, height: Int = 1280, framesPerSecond: Int = 5) throws {
        guard (1...1280).contains(width), (1...1280).contains(height),
              (1...5).contains(framesPerSecond) else { throw NativeWindowCaptureError.invalidLimits }
        self.width = width; self.height = height; self.framesPerSecond = framesPerSecond
    }
}

/// This generation identifies a disposable producer, NOT a WindowServer incarnation.
package struct NativeWindowCaptureFrame: Sendable {
    package let generation: UUID
    package let sequence: UInt64
    package let jpeg: Data
    /// Actual cropped JPEG dimensions, not source-window points or input coordinates.
    package let width: Int
    package let height: Int
}
package enum NativeWindowCaptureAvailability: Sendable, Equatable {
    case available(UUID), unavailable(NativeWindowCaptureError)
}
package enum NativeWindowCaptureJoin: Sendable, Equatable {
    case joined, failed(NativeWindowCaptureError)
}
internal enum NativeWindowCaptureOutput: Sendable {
    case frame(jpeg: Data, width: Int, height: Int)
    case failed(NativeWindowCaptureError)
}
internal protocol NativeWindowCapturePlatform: Sendable {
    func validate() throws
    func makeStream(limits: NativeWindowCaptureLimits,
                    output: @escaping @Sendable (NativeWindowCaptureOutput) -> Void) throws -> any NativeWindowCaptureStream
}
internal protocol NativeWindowCaptureStream: AnyObject, Sendable {
    var retirementFailure: NativeWindowCaptureError? { get }
    func start() async throws
    func requestStop()
    /// Only called after start has returned; must join native stop and callbacks.
    func stopAndJoin() async -> NativeWindowCaptureJoin
}

/// Single-use, pull-only producer. There is one replaceable frame, no consumer
/// callbacks, waiter list, or Task-per-frame queue. Callers own disposal and must
/// carry the returned generation through any asynchronous presentation work.
package final class NativeWindowCapture: @unchecked Sendable {
    private enum State { case idle, starting, running, stopping, stopped, retirementFailed }
    private let lock = NSLock()
    private let platform: any NativeWindowCapturePlatform
    private let limits: NativeWindowCaptureLimits
    private let generation = UUID()
    private var state = State.idle
    private var failure: NativeWindowCaptureError?
    private var joinedRetirementFailure: NativeWindowCaptureError?
    private var latest: NativeWindowCaptureFrame?
    private var sequence: UInt64 = 0
    private var stream: (any NativeWindowCaptureStream)?
    private var startTask: Task<NativeWindowCaptureAvailability, Never>?
    private var stopTask: Task<NativeWindowCaptureJoin, Never>?

    // Internal injection is used only by offline tests; production binds the
    // immutable SCK selection, never an arbitrary platform supplied by a caller.
    internal init(platform: any NativeWindowCapturePlatform, limits: NativeWindowCaptureLimits) {
        self.platform = platform; self.limits = limits
    }
    package convenience init(selection: NativeWindowCaptureSelection, limits: NativeWindowCaptureLimits) {
        self.init(platform: ScreenCaptureKitPlatform(selection: selection), limits: limits)
    }

    package func start() async -> NativeWindowCaptureAvailability {
        if Task.isCancelled { requestStop() }
        let task: Task<NativeWindowCaptureAvailability, Never>? = lock.withLock {
            guard state == .idle || state == .starting || state == .running else { return nil }
            if let startTask { return startTask }
            state = .starting
            let task = Task.detached { [self] in await startStream() }
            startTask = task
            return task
        }
        return await withTaskCancellationHandler {
            let result = await task?.value
            let current: NativeWindowCaptureAvailability = lock.withLock {
                guard state == .running, case .available = result else { return .unavailable(failure ?? .stopped) }
                return .available(generation)
            }
            if case .unavailable = current { _ = await stopAndJoin() }
            return current
        } onCancel: { self.requestStop() }
    }

    private func startStream() async -> NativeWindowCaptureAvailability {
        do {
            try platform.validate()
            guard lock.withLock({ state == .starting }) else { return .unavailable(.stopped) }
            let created = try platform.makeStream(limits: limits) { [weak self, generation] output in
                self?.ingest(output, generation: generation)
            }
            let admitted = lock.withLock {
                stream = created // Stop also owns a stream created after its fence.
                return state == .starting
            }
            guard admitted else { created.requestStop(); return .unavailable(.stopped) }
            try platform.validate()
            try await created.start()
            try platform.validate()
            return lock.withLock {
                guard state == .starting else { return .unavailable(failure ?? .stopped) }
                state = .running
                return .available(generation)
            }
        } catch {
            fail(error as? NativeWindowCaptureError ?? .streamFailed)
            return .unavailable(lock.withLock { failure ?? .streamFailed })
        }
    }

    internal func ingest(_ output: NativeWindowCaptureOutput, generation callbackGeneration: UUID) {
        guard lock.withLock({ generation == callbackGeneration && (state == .starting || state == .running) }) else { return }
        if case let .failed(error) = output { fail(error); return }
        do { try platform.validate() }
        catch { fail(error as? NativeWindowCaptureError ?? .sourceUnavailable); return }
        guard case let .frame(jpeg, width, height) = output else { return }
        guard !jpeg.isEmpty, jpeg.count <= NativeWindowCaptureLimits.maximumEncodedBytes,
              (1...limits.width).contains(width), (1...limits.height).contains(height) else { fail(.malformedFrame); return }
        lock.withLock {
            guard generation == callbackGeneration, state == .starting || state == .running,
                  sequence < UInt64.max else { return }
            // SCK may deliver the only complete frame of a static window before
            // its start completion. Retain one, but pulls stay closed until ready.
            sequence += 1
            latest = .init(generation: generation, sequence: sequence, jpeg: jpeg, width: width, height: height)
        }
    }

    package func takeLatestFrame(generation requested: UUID) throws -> NativeWindowCaptureFrame? {
        try lock.withLock {
            guard state == .running, requested == generation else { throw failure ?? .stopped }
        }
        do { try platform.validate() }
        catch { fail(error as? NativeWindowCaptureError ?? .sourceUnavailable) }
        return try lock.withLock {
            guard state == .running, requested == generation else { throw failure ?? .stopped }
            defer { latest = nil }
            return latest
        }
    }

    /// A native Stop error is observable while joined retirement remains pending.
    package var retirementFailure: NativeWindowCaptureError? {
        let current = lock.withLock { (stream, joinedRetirementFailure) }
        return current.0?.retirementFailure ?? current.1
    }

    private func fail(_ error: NativeWindowCaptureError) { _ = stoppingTask(error: error) }
    package func requestStop() { _ = stoppingTask() }
    package func stopAndJoin() async -> NativeWindowCaptureJoin { await stoppingTask().value }

    private func stoppingTask(error: NativeWindowCaptureError? = nil) -> Task<NativeWindowCaptureJoin, Never> {
        let work: (Task<NativeWindowCaptureJoin, Never>, (any NativeWindowCaptureStream)?) = lock.withLock {
            if let stopTask { return (stopTask, stream) }
            failure = error ?? failure; state = .stopping; latest = nil
            let startup = startTask
            let task = Task.detached { [self] in
                if let startup { _ = await startup.value }
                let installed = lock.withLock { stream }
                let result = await installed?.stopAndJoin() ?? .joined
                let diagnostic = installed?.retirementFailure
                lock.withLock {
                    joinedRetirementFailure = diagnostic
                    // Uncertain native Stop cannot return from the platform join.
                    // A failed output removal still keeps its exact resource owned.
                    if result == .joined { stream = nil; state = .stopped }
                    else { state = .retirementFailed }
                }
                return result
            }
            stopTask = task
            return (task, stream)
        }
        work.1?.requestStop() // Never invoke platform code under the owner lock.
        return work.0
    }

    deinit {
        // Explicit Stop's task retains this owner until completion. Abandonment
        // before Stop instead transfers the exact stream to the same native join
        // path once; closing its callback gate alone would leave capture running.
        if stopTask == nil, let installed = stream {
            installed.requestStop()
            Task.detached { _ = await installed.stopAndJoin() }
        }
    }
}
