import CoreGraphics
import Foundation
import Darwin

/// Literal stream facts; not target authority, application effect or release proof.
internal struct NativeEventFacts: Sendable, Equatable {
    struct Point: Sendable, Hashable {
        let x: Double
        let y: Double
        init(_ point: CGPoint) { x = point.x; y = point.y }
    }
    let type: CGEventType
    let flags: CGEventFlags
    let keyCode: Int64?
    let button: Int64?
    let clickState: Int64?
    let location: Point?
    init(type: CGEventType, flags: CGEventFlags, keyCode: Int64? = nil,
         button: Int64? = nil, clickState: Int64? = nil, location: CGPoint? = nil) {
        self.type = type; self.flags = flags; self.keyCode = keyCode
        self.button = button; self.clickState = clickState; self.location = location.map(Point.init)
    }
    func matches(_ event: CGEvent) -> Bool {
        event.type == type && event.flags == flags
            && (keyCode.map { event.getIntegerValueField(.keyboardEventKeycode) == $0 } ?? true)
            && (button.map { event.getIntegerValueField(.mouseEventButtonNumber) == $0 } ?? true)
            && (clickState.map { event.getIntegerValueField(.mouseEventClickState) == $0 } ?? true)
            && (location.map { event.location.x == $0.x && event.location.y == $0.y } ?? true)
    }
}
package struct NativeStreamGeneration: Hashable, Sendable {
    package let id: UUID
    package let number: UInt64
}
internal struct NativeStreamRegistration: Equatable, Sendable {
    let generation: NativeStreamGeneration
    let ticket: NativeInputEventTicket
    let correlationTag: UInt64
    let expected: NativeEventFacts
}
internal struct NativeStreamSeen: Sendable, Equatable {
    let registration: NativeStreamRegistration
    let type: CGEventType
    let flags: CGEventFlags
    let location: NativeEventFacts.Point
}
internal enum NativeStreamResult: Sendable { case seen(NativeStreamSeen), unavailable(String), cancelled }
internal enum NativeStreamClassification: Sendable { case seen(NativeStreamSeen), activity, unavailable(String) }
package enum NativeEventObserverAvailability: Sendable, Equatable {
    case available(NativeStreamGeneration), unavailable(String)
}
internal enum NativeEventPortState: Sendable, Equatable {
    case ready(eventsOfInterest: CGEventMask, enabled: Bool), unavailable(String)
}
internal protocol NativeEventObserverPlatform: Sendable {
    func makePort(eventsOfInterest: CGEventMask,
                  callback: @escaping @Sendable (CGEventType, CGEvent?) -> Void) throws -> any NativeEventObserverPort
}
internal protocol NativeEventObserverPort: AnyObject, Sendable {
    func start() -> NativeEventPortState
    func health() -> NativeEventPortState
    func requestStop()
    /// Called on the observer's blocking teardown task, never the callback thread.
    func stopAndJoin()
}

private final class StreamWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: NativeStreamResult?
    private var continuation: CheckedContinuation<NativeStreamResult, Never>?
    var completed: Bool { lock.withLock { result != nil } }
    func install(_ continuation: CheckedContinuation<NativeStreamResult, Never>) {
        let immediate: NativeStreamResult? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil as NativeStreamResult?
        }
        if let immediate { continuation.resume(returning: immediate) }
    }
    @discardableResult func resolve(_ result: NativeStreamResult) -> Bool {
        let resolved: (Bool, CheckedContinuation<NativeStreamResult, Never>?) = lock.withLock {
            guard self.result == nil else { return (false, nil) }
            self.result = result
            let continuation = self.continuation; self.continuation = nil
            return (true, continuation)
        }
        resolved.1?.resume(returning: result)
        return resolved.0
    }
}

package final class NativeEventObserver: @unchecked Sendable {
    private enum State { case idle, starting, running, unavailable, stopping, stopped }
    private struct Entry {
        let registration: NativeStreamRegistration
        var waiter: StreamWaiter?
        var result: NativeStreamResult?
        var finished = false
    }
    private let lock = NSLock()
    private let platform: any NativeEventObserverPlatform
    private let maxEvents: Int
    private let activity: @Sendable () -> Void
    private let generation = NativeStreamGeneration(id: UUID(), number: 1)
    private var state = State.idle
    private var reason = "observer has not started"
    private var activityReported = false
    private var entries: [UInt64: Entry] = [:]
    private var tickets = Set<NativeInputEventTicket>()
    private var boundTicket: NativeInputEventTicket?
    private var port: (any NativeEventObserverPort)?
    private var startTask: Task<NativeEventObserverAvailability, Never>?
    private var stopTask: Task<Void, Never>?

    init(platform: any NativeEventObserverPlatform, maxEvents: Int = 512,
         activity: @escaping @Sendable () -> Void = {}) {
        self.platform = platform; self.maxEvents = maxEvents; self.activity = activity
    }

    /// Package-facing construction remains passive and listen-only. The route
    /// is selected once before startup; no failure switches it to another route.
    package convenience init(target: NativeEventTapTarget = .session, maxEvents: Int = 512,
                             activity: @escaping @Sendable () -> Void = {}) {
        self.init(platform: NativeEventTapPlatform(target: target), maxEvents: maxEvents, activity: activity)
    }

    package func start() async -> NativeEventObserverAvailability {
        let task: Task<NativeEventObserverAvailability, Never>? = lock.withLock {
            guard state == .idle || state == .starting || state == .running else { return nil }
            if let startTask { return startTask }
            guard (1...512).contains(maxEvents) else { return nil }
            state = .starting
            let task = Task.detached { [self] in startPort() }
            startTask = task
            return task
        }
        guard let task else { return .unavailable("observer cannot start") }
        return await withTaskCancellationHandler { await task.value } onCancel: { self.requestStop() }
    }

    private func startPort() -> NativeEventObserverAvailability {
        do {
            let created = try platform.makePort(eventsOfInterest: Self.requiredEventsOfInterest) { [weak self, generation] type, event in
                _ = self?.ingest(type: type, event: event, generation: generation)
            }
            let mayStart = lock.withLock {
                port = created // Handoff is visible even if Stop raced with creation.
                return state == .starting
            }
            if !mayStart {
                created.requestStop(); created.stopAndJoin()
                clearJoinedPort(created)
                return .unavailable("observer stopped during creation")
            }
            let result = created.start()
            let adopted = lock.withLock { () -> Bool in
                guard state == .starting, Self.covered(result) else { return false }
                state = .running
                return true
            }
            if adopted { return .available(generation) }
            created.requestStop(); created.stopAndJoin()
            clearJoinedPort(created)
            return markUnavailable("tap startup stopped or permission/mask/health was unavailable")
        } catch { return markUnavailable("tap creation unavailable: \(error)") }
    }

    private func clearJoinedPort(_ joined: any NativeEventObserverPort) {
        lock.withLock { if let current = port, current === joined { port = nil } }
    }

    private static func covered(_ state: NativeEventPortState) -> Bool {
        guard case let .ready(mask, enabled) = state else { return false }
        return enabled && mask == requiredEventsOfInterest
    }

    private func healthy() -> Bool {
        let candidate = lock.withLock { state == .running ? port : nil }
        guard let candidate else { return false }
        guard Self.covered(candidate.health()) else {
            _ = markUnavailable("tap permission, mask or health was lost")
            return false
        }
        return lock.withLock { state == .running }
    }

    func register(ticket: NativeInputEventTicket, expected: NativeEventFacts) throws -> NativeStreamRegistration {
        guard healthy() else { throw NativeObserverError.unavailable("observer is unavailable") }
        return try lock.withLock {
            guard state == .running else { throw NativeObserverError.unavailable(reason) }
            guard entries.count < maxEvents else { throw NativeObserverError.capacity }
            guard !tickets.contains(ticket) else { throw NativeObserverError.duplicateTicket }
            if let boundTicket {
                guard ticket.operationID == boundTicket.operationID, ticket.target == boundTicket.target,
                      ticket.scope == boundTicket.scope else {
                    throw NativeObserverError.unavailable("observer is bound to another operation or source")
                }
            }
            guard Self.observedTypes.contains(expected.type) else {
                throw NativeObserverError.unavailable("unsupported expected event type")
            }
            if let point = expected.location, !point.x.isFinite || !point.y.isFinite {
                throw NativeObserverError.unavailable("invalid expected event position")
            }
            // Random positive tags avoid accepting a prior observer's reused ordinal.
            // Correlation tags are not a grant or a substitute for native host identity.
            var tag = UInt64.random(in: 1...UInt64(Int64.max))
            while entries[tag] != nil { tag = UInt64.random(in: 1...UInt64(Int64.max)) }
            let registration = NativeStreamRegistration(generation: generation, ticket: ticket,
                                                        correlationTag: tag, expected: expected)
            entries[tag] = Entry(registration: registration)
            if boundTicket == nil { boundTicket = ticket }
            tickets.insert(ticket)
            return registration
        }
    }

    func stampedCopy(of event: CGEvent, for registration: NativeStreamRegistration) -> CGEvent? {
        guard healthy() else { return nil }
        return lock.withLock {
            guard state == .running, let entry = entries[registration.correlationTag],
                  entry.registration == registration, !entry.finished, registration.expected.matches(event),
                  let copy = event.copy(), let source = CGEventSource(event: copy) else { return nil }
            // An event can cache its source on first read. Rewriting the integer
            // field alone then leaves userData unchanged on macOS 26.4. Clone
            // the source, set its data and attach it only to the inert copy.
            source.userData = Int64(registration.correlationTag)
            copy.setSource(source)
            guard copy.getIntegerValueField(.eventSourceUserData) == Int64(registration.correlationTag),
                  registration.expected.matches(copy) else { return nil }
            return copy
        }
    }

    func wait(for registration: NativeStreamRegistration) async -> NativeStreamResult {
        guard healthy() else { return .unavailable("observer is unavailable") }
        let waiter = StreamWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if waiter.completed { waiter.install(continuation); return }
                    guard state == .running, var entry = entries[registration.correlationTag],
                          entry.registration == registration else {
                        waiter.resolve(.unavailable("registration is stale or observer ended"))
                        waiter.install(continuation); return
                    }
                    if entry.finished {
                        if waiter.resolve(entry.result ?? .unavailable("observation was already consumed")) {
                            entry.result = nil
                        }
                    } else if let previous = entry.waiter, !previous.completed {
                        waiter.resolve(.unavailable("registration already has a waiter"))
                    } else if !waiter.completed {
                        entry.waiter = waiter
                    }
                    entries[registration.correlationTag] = entry
                    waiter.install(continuation)
                }
            }
        } onCancel: {
            // Cancellation belongs only to this wait, never another waiter's slot.
            waiter.resolve(.cancelled)
        }
    }

    @discardableResult func ingest(type: CGEventType, event: CGEvent?,
                                   generation callbackGeneration: NativeStreamGeneration) -> NativeStreamClassification {
        let active = lock.withLock { generation == callbackGeneration && (state == .running || state == .starting) }
        guard active else { return .unavailable("retired observer callback") }
        guard type != .tapDisabledByTimeout, type != .tapDisabledByUserInput, let event else {
            _ = markUnavailable("tap disabled or callback data missing")
            return .unavailable("tap disabled or callback data missing")
        }
        var activityNeeded = false
        var failure: String?
        let classification: NativeStreamClassification = lock.withLock {
            guard state == .running || state == .starting else { return .unavailable("observer ended") }
            let rawTag = event.getIntegerValueField(.eventSourceUserData)
            guard rawTag > 0, var entry = entries[UInt64(rawTag)] else {
                if !activityReported { activityReported = true; activityNeeded = true }
                return .activity // Do not retain unrelated event objects, text or key data.
            }
            guard !entry.finished else {
                failure = "duplicate native event callback"
                state = .unavailable // Close admission before releasing the callback lock.
                return .unavailable(failure!)
            }
            guard event.type == type, entry.registration.expected.matches(event) else {
                failure = "native event fields did not match registration"
                state = .unavailable
                return .unavailable(failure!)
            }
            let seen = NativeStreamSeen(registration: entry.registration, type: event.type,
                                        flags: event.flags, location: .init(event.location))
            entry.finished = true
            let delivered = entry.waiter?.resolve(.seen(seen)) ?? false
            entry.waiter = nil
            entry.result = delivered ? nil : .seen(seen)
            entries[UInt64(rawTag)] = entry
            return .seen(seen)
        }
        if activityNeeded { activity() }
        if let failure { _ = markUnavailable(failure) }
        return classification
    }

    private func invalidateEntriesLocked(_ message: String) {
        for tag in entries.keys {
            guard var entry = entries[tag] else { continue }
            entry.finished = true
            let delivered = entry.waiter?.resolve(.unavailable(message)) ?? false
            entry.waiter = nil; entry.result = delivered ? nil : .unavailable(message)
            entries[tag] = entry
        }
    }

    private func markUnavailable(_ message: String) -> NativeEventObserverAvailability {
        let stop = lock.withLock { () -> (any NativeEventObserverPort)? in
            guard state != .stopping, state != .stopped else { return nil }
            reason = message; state = .unavailable
            invalidateEntriesLocked(message)
            return port
        }
        stop?.requestStop() // Safe on callback thread: never self-join here.
        return .unavailable(message)
    }

    package func requestStop() { _ = stoppingTask() }

    package func stopAndJoin() async { await stoppingTask().value }

    private func stoppingTask() -> Task<Void, Never> {
        lock.withLock {
            if let stopTask { return stopTask }
            state = .stopping
            invalidateEntriesLocked("observer stopped")
            let startup = startTask
            let candidate = port
            let task = Task.detached { [self] in
                // No platform call runs under the observer lock; a synchronous
                // platform callback must be able to see the stopping fence.
                candidate?.requestStop()
                if let startup { _ = await startup.value }
                let installed = lock.withLock { port }
                installed?.stopAndJoin()
                lock.withLock { port = nil; state = .stopped; entries.removeAll(); tickets.removeAll() }
            }
            stopTask = task
            return task
        }
    }

    deinit { port?.requestStop() } // Explicit stopAndJoin remains the quiescence API.

    private static let observedTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]
    package static let requiredEventsOfInterest: CGEventMask = observedTypes.reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }
}
internal enum NativeObserverError: Error, Equatable { case capacity, duplicateTicket, unavailable(String) }

/// Metadata for one event tap owned by the current process. It contains no event
/// payload, text, key history or screenshot data.
package struct NativeEventTapInventoryEntry: Codable, Equatable, Sendable {
    package let eventTapID: UInt32
    package let tappingProcess: Int32
    package let processBeingTapped: Int32
    package let tapPointRawValue: Int32
    package let optionsRawValue: UInt32
    package let eventsOfInterest: UInt64
    package let enabled: Bool

}

package enum NativeEventTapInventory {
    /// Returns only the bounded metadata inventory for this process. This is a
    /// read-only diagnostic; it neither creates taps nor requests permission.
    package static func currentProcess() throws -> [NativeEventTapInventoryEntry] {
        let capacity: UInt32 = 64
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count <= capacity else {
            throw NativeObserverError.unavailable("tap inventory is unavailable or exceeds bound")
        }
        var values = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(capacity))
        let result = values.withUnsafeMutableBufferPointer { CGGetEventTapList(capacity, $0.baseAddress, &count) }
        guard result == .success, count <= capacity else {
            throw NativeObserverError.unavailable("tap inventory changed beyond bound")
        }
        let pid = Int32(getpid())
        return values.prefix(Int(count)).filter { Int32($0.tappingProcess) == pid }.map {
            .init(eventTapID: $0.eventTapID, tappingProcess: Int32($0.tappingProcess),
                  processBeingTapped: Int32($0.processBeingTapped),
                  tapPointRawValue: Int32($0.tapPoint.rawValue),
                  optionsRawValue: UInt32($0.options.rawValue),
                  eventsOfInterest: UInt64($0.eventsOfInterest), enabled: $0.enabled)
        }
    }
}

/// A process tap is a distinct route, never a fallback for a failed session tap.
/// The caller must bind the PID to its live, owned target; this value is not a grant.
package enum NativeEventTapTarget: Equatable, Sendable {
    case session
    case process(Int32)

    var isValid: Bool {
        switch self { case .session: true; case let .process(pid): pid > 0 }
    }
    func matches(_ entry: NativeEventTapInventoryEntry, mask: CGEventMask) -> Bool {
        guard isValid, entry.enabled, entry.eventsOfInterest == mask,
              entry.optionsRawValue == UInt32(CGEventTapOptions.listenOnly.rawValue) else { return false }
        switch self {
        case .session:
            return entry.processBeingTapped == 0 && entry.tapPointRawValue == Int32(CGEventTapLocation.cgSessionEventTap.rawValue)
        case let .process(pid):
            // Process tap location metadata is not a session-route claim. The
            // processBeingTapped field must identify the exact requested PID.
            return entry.processBeingTapped == pid
        }
    }
}

/// Explicit-start factory only. No permission request or tap occurs at package load.
internal struct NativeEventTapPlatform: NativeEventObserverPlatform {
    let target: NativeEventTapTarget
    func makePort(eventsOfInterest: CGEventMask,
                  callback: @escaping @Sendable (CGEventType, CGEvent?) -> Void) throws -> any NativeEventObserverPort {
        guard target.isValid else { throw NativeObserverError.unavailable("invalid event-tap target") }
        guard CGPreflightListenEventAccess() else { throw NativeObserverError.unavailable("listen-event permission is not granted") }
        return try NativeEventTapPort(target: target, eventsOfInterest: eventsOfInterest, callback: callback)
    }
}

private final class NativeEventTapPort: @unchecked Sendable, NativeEventObserverPort {
    private final class CallbackBox {
        let callback: @Sendable (CGEventType, CGEvent?) -> Void
        init(_ callback: @escaping @Sendable (CGEventType, CGEvent?) -> Void) { self.callback = callback }
    }
    private let condition = NSCondition()
    private let callbackBox: CallbackBox
    private let tap: CFMachPort
    private let tapID: UInt32
    private let requestedMask: CGEventMask
    private let target: NativeEventTapTarget
    private var runLoop: CFRunLoop?
    private var worker: Thread?
    private var stopRequested = false
    private var exited = false
    private var startup: NativeEventPortState?

    init(target: NativeEventTapTarget, eventsOfInterest: CGEventMask, callback: @escaping @Sendable (CGEventType, CGEvent?) -> Void) throws {
        self.target = target
        callbackBox = CallbackBox(callback)
        requestedMask = eventsOfInterest
        let before = Set(try NativeEventTapInventory.currentProcess().map(\.eventTapID))
        let handler: CGEventTapCallBack = { _, type, event, info in
            guard let info else {
                // The run-loop owner still holds the callback box. End delivery;
                // worker retirement reports unavailable through that owned box.
                CFRunLoopStop(CFRunLoopGetCurrent())
                return Unmanaged.passUnretained(event)
            }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            box.callback(type, event)
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            return Unmanaged.passUnretained(event)
        }
        let info = Unmanaged.passUnretained(callbackBox).toOpaque()
        let candidate: CFMachPort?
        switch target {
        case .session:
            candidate = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: eventsOfInterest, callback: handler, userInfo: info)
        case let .process(pid):
            candidate = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: eventsOfInterest, callback: handler, userInfo: info)
        }
        guard let created = candidate else { throw NativeObserverError.unavailable("event tap creation returned nil") }
        do {
            let added = try NativeEventTapInventory.currentProcess().filter { !before.contains($0.eventTapID) }
            guard added.count == 1, let entry = added.first,
                  target.matches(entry, mask: eventsOfInterest) else {
                throw NativeObserverError.unavailable("new tap identity is missing or ambiguous")
            }
            tap = created; tapID = entry.eventTapID
        } catch { CFMachPortInvalidate(created); throw error }
    }

    func start() -> NativeEventPortState {
        condition.lock()
        if stopRequested || exited { condition.unlock(); return .unavailable("tap stopped before startup") }
        let launch: Thread?
        if worker == nil {
            let thread = Thread { [self] in
                run()
                // Also settles pending reads if the loop exits without a usable
                // callback context. Stream loss is never native release proof.
                callbackBox.callback(.null, nil)
                // Publish retirement only after run() released its local source.
                // Break the Thread/block/port cycle before waking joiners.
                condition.lock()
                worker = nil; exited = true
                condition.broadcast(); condition.unlock()
            }
            worker = thread; launch = thread
        } else { launch = nil }
        condition.unlock()
        launch?.start()
        condition.lock()
        while startup == nil { condition.wait() }
        let result = startup!
        condition.unlock()
        return result
    }

    func health() -> NativeEventPortState {
        guard !condition.withLock({ stopRequested || exited }), CGPreflightListenEventAccess(),
              CGEvent.tapIsEnabled(tap: tap), let inventory = try? NativeEventTapInventory.currentProcess(),
              let info = inventory.first(where: { $0.eventTapID == tapID && $0.tappingProcess == Int32(getpid()) }),
              target.matches(info, mask: requestedMask) else {
            return .unavailable("tap health or identity is unavailable")
        }
        return .ready(eventsOfInterest: info.eventsOfInterest, enabled: info.enabled)
    }

    func requestStop() {
        condition.lock()
        stopRequested = true
        let loop = runLoop
        let unstarted = worker == nil
        condition.unlock()
        CFMachPortInvalidate(tap)
        if let loop {
            // An enqueued block also covers Stop racing just before CFRunLoopRun.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(loop)
        }
        if unstarted {
            condition.lock()
            startup = .unavailable("tap stopped before worker startup")
            exited = true
            condition.broadcast(); condition.unlock()
        }
    }

    func stopAndJoin() {
        requestStop()
        condition.lock()
        while !exited { condition.wait() }
        condition.unlock()
    }

    private func run() {
        let loop = CFRunLoopGetCurrent()!
        if condition.withLock({ stopRequested }) { finish(); return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { finish(); return }
        CFRunLoopAddSource(loop, source, .defaultMode)
        condition.withLock { runLoop = loop }
        let ready = health()
        condition.lock()
        startup = stopRequested ? .unavailable("tap stopped during startup") : ready
        condition.broadcast()
        let shouldRun = !stopRequested && { if case .ready = ready { return true }; return false }()
        condition.unlock()
        if shouldRun { CFRunLoopRun() }
        CFRunLoopRemoveSource(loop, source, .defaultMode)
        finish()
    }

    private func finish() {
        CFMachPortInvalidate(tap)
        condition.lock()
        if startup == nil { startup = .unavailable("tap startup ended") }
        runLoop = nil
        condition.broadcast(); condition.unlock()
    }

    deinit { CFMachPortInvalidate(tap) }
}
