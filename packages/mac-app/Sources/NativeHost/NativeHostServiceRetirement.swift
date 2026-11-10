import Foundation

public struct NativeHostServiceRetirement: Sendable {
    private let captures: NativeCaptureSlot
    private let retireAutomation: @Sendable () async -> Void
    private let terminate: @Sendable () -> Void

    public init(captures: NativeCaptureSlot, retireAutomation: @escaping @Sendable () async -> Void,
                terminate: @escaping @Sendable () -> Void) {
        self.captures = captures; self.retireAutomation = retireAutomation; self.terminate = terminate
    }

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
