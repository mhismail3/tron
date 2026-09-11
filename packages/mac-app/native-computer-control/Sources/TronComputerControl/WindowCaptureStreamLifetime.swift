import Foundation

/// The SCK adapter's sole native start/Stop/callback state. SDK calls are supplied
/// at the boundary so offline tests exercise this same retirement path, not an
/// alternate stream that simply returns an expected join result.
internal final class WindowCaptureStreamLifetime: @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false
    private var retired = false
    private var callbacks = 0
    private var attemptedStart = false
    private var nativeStopped = false
    private var stopFailure: NativeWindowCaptureError?
    private var terminalWaiter: CheckedContinuation<Void, Never>?

    var isClosed: Bool { condition.withLock { closed } }
    var retirementFailure: NativeWindowCaptureError? { condition.withLock { stopFailure } }

    func beginStart() -> Bool {
        condition.withLock {
            guard !closed, !attemptedStart else { return false }
            attemptedStart = true
            return true
        }
    }

    func requestStop() { condition.withLock { closed = true } }

    /// Ordinary output closes immediately. A terminal receipt remains eligible
    /// during uncertain Stop, but never after the final callback-retirement seal.
    @discardableResult
    func withCallback(terminal: Bool = false, _ body: (_ mayPublish: Bool) -> Void) -> Bool {
        let admission: Bool? = condition.withLock {
            guard !retired, terminal || !closed else { return nil }
            callbacks += 1
            return !closed
        }
        guard let admission else { return false }
        body(admission)
        condition.lock()
        callbacks -= 1
        let waiter: CheckedContinuation<Void, Never>?
        if terminal {
            nativeStopped = true
            waiter = terminalWaiter
            terminalWaiter = nil
        } else { waiter = nil }
        condition.broadcast()
        condition.unlock()
        waiter?.resume()
        return true
    }

    /// The containing owner serializes this once, after the actual start call has
    /// returned, including failed starts. An error is not terminal native evidence.
    func stopAndJoin(stop: @Sendable () async throws -> Void,
                     removeOutput: @Sendable () throws -> Void,
                     sampleQueue: DispatchQueue) async -> NativeWindowCaptureJoin {
        requestStop()
        if condition.withLock({ attemptedStart && !nativeStopped }) {
            do { try await stop() }
            catch {
                await withCheckedContinuation { continuation in
                    let terminal = condition.withLock {
                        stopFailure = .stopFailed
                        if nativeStopped { return true }
                        terminalWaiter = continuation
                        return false
                    }
                    if terminal { continuation.resume() }
                }
            }
        }
        var result = NativeWindowCaptureJoin.joined
        do { try removeOutput() }
        catch { condition.withLock { stopFailure = .stopFailed }; result = .failed(.stopFailed) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                sampleQueue.sync {}
                condition.lock()
                while callbacks != 0 { condition.wait() }
                // No terminal callback can enter between the zero observation
                // and completion: checking and sealing use the same gate.
                retired = true
                condition.unlock()
                continuation.resume()
            }
        }
        return result
    }
}
