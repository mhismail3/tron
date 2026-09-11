import Foundation

/// Bounded authenticated transports are distinct from the ONE native stream.
/// A catalogue/idle connection owns no stream capacity. Only actual joined
/// retirement releases a reservation; diagnostics remain visible separately.
public final class NativeCaptureSlot: @unchecked Sendable {
    public init() {}
    let bootID = UUID()
    private let lock = NSLock()
    private var closed = false
    private var handshakes: Set<UUID> = []
    private var sessions: [UUID: NativeCaptureSession] = [:]
    private var streamOwner: UUID?

    func beginHandshake() -> UUID? {
        lock.withLock {
            guard !closed, handshakes.count < 4, sessions.count < 4 else { return nil }
            let id = UUID(); handshakes.insert(id); return id
        }
    }
    func finishHandshake(_ id: UUID, fence: NativeCaptureFence, operations: NativeCaptureOperations) -> NativeCaptureSession? {
        lock.withLock {
            guard handshakes.remove(id) != nil, !closed, sessions.count < 4 else { return nil }
            let session = NativeCaptureSession(bootID: bootID, ownerID: id, slot: self, fence: fence, operations: operations)
            sessions[id] = session
            return session
        }
    }
    func abandonHandshake(_ id: UUID) { lock.withLock { _ = handshakes.remove(id) } }
    func reserveStream(_ id: UUID) -> Bool {
        lock.withLock {
            guard !closed, sessions[id] != nil, streamOwner == nil else { return false }
            streamOwner = id; return true
        }
    }
    func releaseStream(_ id: UUID) { lock.withLock { if streamOwner == id { streamOwner = nil } } }
    func peerLost(_ id: UUID) {
        let session = lock.withLock { sessions[id] }
        guard let session else { return }
        session.fence.close()
        Task { [self] in
            guard await session.drain().joined else { return }
            lock.withLock { _ = sessions.removeValue(forKey: id) }
        }
    }
    public func drainForServiceRetirement() async -> Bool {
        let current = lock.withLock { closed = true; return Array(sessions.values) }
        for session in current { session.fence.close() }
        var joined = true
        for session in current { if !(await session.drain().joined) { joined = false } }
        // Pending handshakes have no native work and cannot install after closed.
        return joined
    }
}

final class NativeCaptureService: NSObject, TronNativeCaptureService, @unchecked Sendable {
    private let session: NativeCaptureSession
    private let lock = NSLock()
    private var replies = 0
    private var stopReplies = 0
    init(session: NativeCaptureSession) { self.session = session }

    func executeCaptureRequest(_ data: Data, withReply reply: @escaping @Sendable (Data, Data?) -> Void) {
        let request: NativeCaptureRequest
        do { request = try NativeCaptureRequest.decode(data) }
        catch { reply(NativeCaptureResponse.error(.invalidRequest).control, nil); return }
        let stop = request.operation == "stop" || request.operation == "suspend"
        guard lock.withLock({
            if stop { guard stopReplies < 2 else { return false }; stopReplies += 1 }
            else { guard replies < 8 else { return false }; replies += 1 }
            return true
        }) else { reply(NativeCaptureResponse.error(.busy).control, nil); return }
        Task { [self] in
            let value = await session.execute(request)
            let deliver = stop || session.fence.admits()
            // No async hop after this exact delivery fence. The client must also
            // fence decode/render; a value handed to XPC cannot be revoked.
            reply(deliver ? value.control : NativeCaptureResponse.error(.stale).control, deliver ? value.jpeg : nil)
            lock.withLock { if stop { stopReplies -= 1 } else { replies -= 1 } }
        }
    }
}

/// Deadline closes activation admission but retains the real validation task
/// until it returns. In particular, timed-out launchctl work cannot install late.
final class NativeCaptureHandshake: @unchecked Sendable {
    private enum State { case validating, active, retired }
    private let lock = NSLock()
    private var state = State.validating
    private var task: Task<Void, Never>?
    func install(_ task: Task<Void, Never>) {
        let cancel = lock.withLock { self.task = task; return state == .retired }
        if cancel { task.cancel() }
    }
    func retire() {
        let task = lock.withLock { state = .retired; return self.task }
        task?.cancel()
    }
    func expire() -> Bool {
        let result: (Bool, Task<Void, Never>?) = lock.withLock {
            guard state == .validating else { return (false, nil) }
            state = .retired
            return (true, task)
        }
        result.1?.cancel()
        return result.0
    }
    func activate(_ action: () -> Void) -> Bool {
        lock.withLock {
            guard state == .validating else { return false }
            // Linearize readiness before cancelling the timer. An already-woken
            // deadline must not invalidate a successfully admitted connection.
            state = .active
            action()
            return true
        }
    }
    func finished() { lock.withLock { task = nil } }
}

// NSXPC serializes message/handler delivery. This immutable reference only
// configures before activation or invalidates; handshake locking fences the two.
private final class NativeCaptureTransport: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

public final class NativeCaptureListener: NSObject, NSXPCListenerDelegate {
    private let slot: NativeCaptureSlot
    private let context: NativeCaptureContext
    public init(slot: NativeCaptureSlot, context: NativeCaptureContext) { self.slot = slot; self.context = context }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let id = slot.beginHandshake() else { return false }
        let handshake = NativeCaptureHandshake()
        connection.invalidationHandler = { [slot] in handshake.retire(); slot.peerLost(id) }
        connection.interruptionHandler = { [slot, weak connection] in
            handshake.retire(); slot.peerLost(id); connection?.invalidate()
        }
        let transport = NativeCaptureTransport(connection)
        let task = Task { [slot, context, transport] in
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if handshake.expire() { transport.connection.invalidate() }
            }
            defer { deadline.cancel(); handshake.finished(); slot.abandonHandshake(id) }
            do {
                let peer = try NativeCapturePeer(connection: transport.connection, context: context)
                guard !Task.isCancelled else { transport.connection.invalidate(); return }
                transport.connection.setCodeSigningRequirement(peer.codeRequirement)
                let fence = NativeCaptureFence { peer.isCurrent() }
                guard await peer.validate(), fence.admits(), !Task.isCancelled else { transport.connection.invalidate(); return }
                let activated = handshake.activate {
                    guard let session = slot.finishHandshake(id, fence: fence,
                        operations: .live(peer: peer, automationEndpoint: context.automationEndpoint)) else { transport.connection.invalidate(); return }
                    transport.connection.exportedInterface = NSXPCInterface(with: TronNativeCaptureService.self)
                    transport.connection.exportedObject = NativeCaptureService(session: session)
                    transport.connection.activate()
                }
                if !activated { transport.connection.invalidate() }
            } catch { transport.connection.invalidate() }
        }
        handshake.install(task)
        return true // Remains inactive until authenticated Stable admission.
    }
}
