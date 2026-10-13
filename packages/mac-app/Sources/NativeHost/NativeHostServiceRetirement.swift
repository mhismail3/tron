import Foundation

/// Owns the helper side of wrapper-authorized service retirement: join capture
/// and automation work, confirm, then end the process.
///
/// The wrapper pins this helper's code signature on its connection, so libxpc
/// validates every reply against the live sender. A reply whose sender has
/// already exited fails that check (`errSecCSNoSuchCode`) and reaches the
/// wrapper as an interruption; the wrapper then correctly refuses to treat
/// retirement as confirmed. The helper therefore exits only after the retiring
/// wrapper closes that connection — it does so once it has read the reply, or
/// by exiting itself — never right after queueing the reply. No timer stands
/// in for that close.
public struct NativeHostServiceRetirement: Sendable {
    private let captures: NativeCaptureSlot
    private let retireAutomation: @Sendable () async -> Void
    private let terminate: @Sendable () -> Void

    public init(captures: NativeCaptureSlot, retireAutomation: @escaping @Sendable () async -> Void,
                terminate: @escaping @Sendable () -> Void) {
        self.captures = captures; self.retireAutomation = retireAutomation; self.terminate = terminate
    }

    /// Call on the requesting connection's XPC queue, where that connection is
    /// current and its invalidation cannot yet have been delivered.
    public func prepare(withReply reply: @escaping @Sendable (Bool) -> Void) {
        guard let peer = NSXPCConnection.current() else { reply(false); return }
        let exit = RetirementExit(terminate: terminate)
        peer.invalidationHandler = { exit.peerClosed() }
        Task {
            let joined = await captures.drainForServiceRetirement()
            await retireAutomation()
            reply(joined)
            exit.settle(joined: joined)
        }
    }
}

/// Exits once both the joined confirmation was handed to XPC and its peer closed,
/// in either order. Unjoined retirement never exits: the helper stays alive.
private final class RetirementExit: @unchecked Sendable {
    private let lock = NSLock()
    private let terminate: @Sendable () -> Void
    private var closed = false
    private var joined: Bool?
    private var fired = false
    init(terminate: @escaping @Sendable () -> Void) { self.terminate = terminate }

    func peerClosed() { decide { closed = true } }
    func settle(joined: Bool) { decide { self.joined = joined } }

    private func decide(_ update: () -> Void) {
        let fire = lock.withLock {
            update()
            guard closed, joined == true, !fired else { return false }
            fired = true
            return true
        }
        if fire { terminate() }
    }
}
