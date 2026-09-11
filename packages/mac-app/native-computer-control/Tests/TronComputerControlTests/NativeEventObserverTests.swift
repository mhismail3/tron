import CoreGraphics
import Foundation
import XCTest
@testable import TronComputerControl

final class NativeEventObserverTests: XCTestCase {
    func testProcessTapIdentityCannotBecomeSessionOrForeignProcess() {
        let mask = NativeEventObserver.requiredEventsOfInterest
        func entry(process: Int32, mask: UInt64, enabled: Bool = true) -> NativeEventTapInventoryEntry {
            .init(eventTapID: 9, tappingProcess: 100, processBeingTapped: process,
                  tapPointRawValue: Int32(CGEventTapLocation.cgSessionEventTap.rawValue),
                  optionsRawValue: UInt32(CGEventTapOptions.listenOnly.rawValue),
                  eventsOfInterest: mask, enabled: enabled)
        }
        let target = NativeEventTapTarget.process(42)
        XCTAssertTrue(target.matches(entry(process: 42, mask: mask), mask: mask))
        XCTAssertFalse(target.matches(entry(process: 0, mask: mask), mask: mask))
        XCTAssertFalse(target.matches(entry(process: 43, mask: mask), mask: mask))
        XCTAssertFalse(target.matches(entry(process: 42, mask: mask | 1), mask: mask))
        XCTAssertFalse(target.matches(entry(process: 42, mask: mask, enabled: false), mask: mask))
        XCTAssertFalse(NativeEventTapTarget.process(0).isValid)
        XCTAssertFalse(NativeEventTapTarget.process(-1).isValid)
        XCTAssertTrue(NativeEventTapTarget.session.matches(entry(process: 0, mask: mask), mask: mask))
        XCTAssertFalse(NativeEventTapTarget.session.matches(entry(process: 42, mask: mask), mask: mask))
    }

    func testRegistrationClonesAndDeliversExactlyOneSeenResult() async throws {
        try await withFixture { f in
            let registration = try f.register()
            let raw = try f.event()
            // Prime Core Graphics' cached source before stamping: field-only
            // rewrites returned zero and previously orphaned the observation.
            XCTAssertEqual(raw.getIntegerValueField(.eventSourceUserData), 0)
            let stamped = try XCTUnwrap(f.observer.stampedCopy(of: raw, for: registration))
            XCTAssertEqual(raw.getIntegerValueField(.eventSourceUserData), 0)
            XCTAssertEqual(stamped.getIntegerValueField(.eventSourceUserData), Int64(registration.correlationTag))
            f.port.emit(stamped)
            let result = await f.observer.wait(for: registration)
            guard case let .seen(seen) = result else { return XCTFail("Expected seen") }
            XCTAssertEqual(seen.registration, registration)
            XCTAssertEqual(seen.type, .keyDown)
            XCTAssertEqual(seen.flags, .maskShift)
            let duplicateWait = await f.observer.wait(for: registration)
            guard case .unavailable = duplicateWait else { return XCTFail("Seen result must be consumed once") }
        }
    }

    func testStampingPreservesPrivateSourceTableWithoutMutatingOriginals() async throws {
        try await withFixture { f in
            let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
            let unrelated = try XCTUnwrap(CGEventSource(stateID: .privateState))
            let sourceID = source.sourceStateID
            XCTAssertNotEqual(sourceID, .privateState)
            XCTAssertNotEqual(sourceID, .combinedSessionState)
            XCTAssertNotEqual(sourceID, .hidSystemState)
            XCTAssertNotEqual(sourceID, unrelated.sourceStateID)
            let before = CGEventSource.keyState(sourceID, key: 0)
            for (ordinal, down) in [true, false].enumerated() {
                let original = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down))
                original.flags = .maskShift
                let type: CGEventType = down ? .keyDown : .keyUp
                let registration = try f.observer.register(ticket: f.ticket(ordinal: ordinal),
                    expected: .init(type: type, flags: .maskShift, keyCode: 0))
                XCTAssertEqual(original.getIntegerValueField(.eventSourceUserData), 0)
                let stamped = try XCTUnwrap(f.observer.stampedCopy(of: original, for: registration))
                XCTAssertFalse(stamped === original)
                XCTAssertEqual(stamped.type, type)
                XCTAssertEqual(stamped.getIntegerValueField(.eventSourceStateID), Int64(sourceID.rawValue))
                let reconstructed = try XCTUnwrap(CGEventSource(event: stamped))
                XCTAssertEqual(reconstructed.sourceStateID, sourceID)
                XCTAssertEqual(stamped.getIntegerValueField(.eventSourceUserData), Int64(registration.correlationTag))
                XCTAssertEqual(original.getIntegerValueField(.eventSourceUserData), 0)
                XCTAssertEqual(original.getIntegerValueField(.eventSourceStateID), Int64(sourceID.rawValue))
            }
            XCTAssertEqual(source.userData, 0)
            // No post or tap callback occurs. This is source-copy preservation,
            // not evidence of delivery or release of any native input.
            XCTAssertEqual(CGEventSource.keyState(sourceID, key: 0), before)
        }
    }

    func testWrongNativeFieldsInvalidateAllPendingObservations() async throws {
        try await withFixture { f in
            let first = try f.register()
            let second = try f.register(ordinal: 1)
            let changed = try XCTUnwrap(f.observer.stampedCopy(of: f.event(), for: first))
            changed.setIntegerValueField(.keyboardEventKeycode, value: 11)
            f.port.emit(changed)
            let result = await f.observer.wait(for: second)
            guard case .unavailable = result else { return XCTFail("Mismatch must invalidate pending source") }
            XCTAssertTrue(f.port.stopWasRequested)
            XCTAssertThrowsError(try f.register(ordinal: 2))
        }
    }

    func testDuplicateNativeCallbackInvalidatesTheSource() async throws {
        try await withFixture { f in
            let registration = try f.register()
            let stamped = try XCTUnwrap(f.observer.stampedCopy(of: f.event(), for: registration))
            f.port.emit(stamped)
            let result = await f.observer.wait(for: registration)
            guard case .seen = result else { return XCTFail("Expected first observation") }
            f.port.emit(stamped)
            XCTAssertThrowsError(try f.register(ordinal: 1))
            XCTAssertTrue(f.port.stopWasRequested)
        }
    }

    func testForeignTextProducesOneActivitySignalWithoutConsumingCapacity() async throws {
        try await withFixture(maxEvents: 1) { f in
            let foreign = try f.event()
            let text: [UInt16] = [65, 66, 67]
            text.withUnsafeBufferPointer { foreign.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            for _ in 0..<100 { f.port.emit(foreign) }
            XCTAssertEqual(f.activity.value, 1)
            _ = try f.register()
            XCTAssertThrowsError(try f.register(ordinal: 1)) { XCTAssertEqual($0 as? NativeObserverError, .capacity) }
        }
    }

    func testUnsupportedTypesAndForeignBindingsCannotRegister() async throws {
        try await withFixture { f in
            _ = try f.register()
            XCTAssertThrowsError(try f.register()) { XCTAssertEqual($0 as? NativeObserverError, .duplicateTicket) }
            for type in [CGEventType.null, .tapDisabledByTimeout] {
                XCTAssertThrowsError(try f.observer.register(ticket: f.ticket(ordinal: 1), expected: .init(type: type, flags: [])))
            }
            let foreign = NativeInputEventTicket(operationID: UUID(), target: f.target, scope: f.scope,
                                                  eventOrdinal: 1, sequence: 2)
            XCTAssertThrowsError(try f.observer.register(ticket: foreign, expected: f.facts))
        }
    }

    func testCorrelationDoesNotReuseOrdinalsAcrossObserverInstances() async throws {
        let a = ObserverFixture()
        let b = ObserverFixture()
        do {
            try await a.start(); try await b.start()
            let first = try a.register()
            let next = try b.register()
            XCTAssertNotEqual(first.correlationTag, next.correlationTag)
            let old = try XCTUnwrap(a.observer.stampedCopy(of: a.event(), for: first))
            b.port.emit(old)
            XCTAssertEqual(b.activity.value, 1)
            let current = try XCTUnwrap(b.observer.stampedCopy(of: b.event(), for: next))
            b.port.emit(current)
            guard case .seen = await b.observer.wait(for: next) else {
                XCTFail("Expected only current source"); throw ObserverTestFailure()
            }
        } catch { await a.finish(); await b.finish(); throw error }
        await a.finish(); await b.finish()
    }

    func testStoppedCallbacksCannotSignalActivityOrRestoreSeenPixels() async throws {
        try await withFixture { f in
            let registration = try f.register()
            let event = try XCTUnwrap(f.observer.stampedCopy(of: f.event(), for: registration))
            await f.observer.stopAndJoin()
            f.port.emit(event)
            f.port.emit(try f.event())
            f.port.emit(nil, type: .tapDisabledByTimeout)
            XCTAssertEqual(f.activity.value, 0)
            XCTAssertNil(f.observer.stampedCopy(of: event, for: registration))
            guard case .unavailable = await f.observer.wait(for: registration) else { return XCTFail("Stopped source revived") }
        }
    }

    func testForeignGenerationCannotConsumeARegistrationOrSignalActivity() async throws {
        try await withFixture { f in
            let registration = try f.register()
            let stamped = try XCTUnwrap(f.observer.stampedCopy(of: f.event(), for: registration))
            let foreign = NativeStreamGeneration(id: UUID(), number: registration.generation.number)
            guard case .unavailable = f.observer.ingest(type: stamped.type, event: stamped, generation: foreign) else {
                return XCTFail("Foreign callback generation was admitted")
            }
            _ = f.observer.ingest(type: .keyDown, event: try f.event(), generation: foreign)
            XCTAssertEqual(f.activity.value, 0)
            f.port.emit(stamped)
            guard case .seen = await f.observer.wait(for: registration) else { return XCTFail("Stale callback consumed result") }
        }
    }

    func testMissingCallbackDataSettlesPendingReaders() async throws {
        try await withFixture { f in
            let registration = try f.register()
            let results = StreamResults()
            let first = Task { results.append(await f.observer.wait(for: registration)) }
            let second = Task { results.append(await f.observer.wait(for: registration)) }
            do {
                try await observerEventually { results.count == 1 }
                f.port.emit(nil, type: .null)
                try await observerEventually { results.count == 2 }
            } catch {
                await f.observer.stopAndJoin()
                _ = await (first.value, second.value)
                throw error
            }
            _ = await (first.value, second.value)
            XCTAssertEqual(results.unavailableCount, 2)
            XCTAssertTrue(f.port.stopWasRequested)
        }
    }

    func testCopiedForeignRegistrationCannotStampAnEvent() async throws {
        try await withFixture { f in
            let actual = try f.register()
            let invented = NativeStreamRegistration(generation: actual.generation, ticket: f.ticket(ordinal: 1),
                                                      correlationTag: actual.correlationTag, expected: actual.expected)
            XCTAssertNil(f.observer.stampedCopy(of: try f.event(), for: invented))
            let wrong = try f.event(); wrong.flags = []
            XCTAssertNil(f.observer.stampedCopy(of: wrong, for: actual))
        }
    }

    func testTwoWaitersDoNotOverwriteOrOrphanTheFirstContinuation() async throws {
        try await withFixture { f in
            let registration = try f.register()
            let results = StreamResults()
            let first = Task { let result = await f.observer.wait(for: registration); results.append(result) }
            let second = Task { let result = await f.observer.wait(for: registration); results.append(result) }
            do {
                // Exactly one returns busy before any event. This proves the other
                // has installed its waiter, without a scheduler-yield assumption.
                try await observerEventually { results.count == 1 }
                let event = try XCTUnwrap(f.observer.stampedCopy(of: f.event(), for: registration))
                f.port.emit(event)
                try await observerEventually { results.count == 2 }
            } catch {
                await f.observer.stopAndJoin()
                _ = await (first.value, second.value)
                throw error
            }
            _ = await (first.value, second.value)
            XCTAssertEqual(results.seenCount, 1)
            XCTAssertEqual(results.unavailableCount, 1)
        }
    }

    func testCancelledWaitDoesNotPoisonTheRegistration() async throws {
        try await withFixture { f in
            let registration = try f.register()
            let task = Task { await f.observer.wait(for: registration) }
            task.cancel()
            guard case .cancelled = await task.value else { return XCTFail("Expected waiter cancellation") }
            let event = try XCTUnwrap(f.observer.stampedCopy(of: f.event(), for: registration))
            f.port.emit(event)
            guard case .seen = await f.observer.wait(for: registration) else { return XCTFail("Cancellation lost event") }
        }
    }

    func testPreCancelledWaitDoesNotConsumeAnAlreadySeenResult() async throws {
        try await withFixture { f in
            let registration = try f.register()
            f.port.emit(try XCTUnwrap(f.observer.stampedCopy(of: f.event(), for: registration)))
            let gate = ObserverAsyncGate()
            let task = Task { await gate.wait(); return await f.observer.wait(for: registration) }
            task.cancel(); gate.open()
            guard case .cancelled = await task.value else { return XCTFail("Expected pre-cancelled wait") }
            guard case .seen = await f.observer.wait(for: registration) else { return XCTFail("Cancelled waiter consumed cache") }
        }
    }

    func testHealthLossAndDisabledCallbacksNeverSilentlyReenable() async throws {
        try await withFixture { f in
            let registration = try f.register()
            f.port.setHealth(.ready(eventsOfInterest: 0, enabled: true))
            XCTAssertNil(f.observer.stampedCopy(of: try f.event(), for: registration))
            XCTAssertTrue(f.port.stopWasRequested)
            f.port.setHealth(.ready(eventsOfInterest: NativeEventObserver.requiredEventsOfInterest, enabled: true))
            XCTAssertThrowsError(try f.register(ordinal: 1))
            guard case .unavailable = await f.observer.start() else { return XCTFail("Reused a stale ready result") }
        }
        try await withFixture { f in
            let registration = try f.register()
            f.port.setHealth(.ready(eventsOfInterest: NativeEventObserver.requiredEventsOfInterest | 1, enabled: true))
            XCTAssertNil(f.observer.stampedCopy(of: try f.event(), for: registration))
            XCTAssertTrue(f.port.stopWasRequested)
        }
        try await withFixture { f in
            let registration = try f.register()
            f.port.emit(nil, type: .tapDisabledByUserInput)
            guard case .unavailable = await f.observer.wait(for: registration) else { return XCTFail("Disabled tap remained usable") }
        }
    }

    func testPartialMaskDisabledAndStopBeforeStartNeverPublishAvailable() async throws {
        for state in [NativeEventPortState.ready(eventsOfInterest: 0, enabled: true),
                      .ready(eventsOfInterest: NativeEventObserver.requiredEventsOfInterest | 1, enabled: true),
                      .ready(eventsOfInterest: NativeEventObserver.requiredEventsOfInterest, enabled: false)] {
            let f = ObserverFixture(state: state)
            guard case .unavailable = await f.observer.start() else { await f.finish(); return XCTFail("Bad tap admitted") }
            XCTAssertEqual(f.port.joinCount, 1)
            await f.finish()
        }
        let f = ObserverFixture()
        await f.observer.stopAndJoin()
        guard case .unavailable = await f.observer.start() else { return XCTFail("Stopped observer started") }
        XCTAssertFalse(f.platform.makeEntered)
    }

    func testStopDuringPortCreationJoinsTheEventuallyCreatedPort() async throws {
        let f = ObserverFixture(blockMake: true)
        let started = Task { await f.observer.start() }
        let stopped = ActivityCounter()
        do {
            try await observerEventually { f.platform.makeEntered }
            let stopping = Task { await f.observer.stopAndJoin(); stopped.increment() }
            f.observer.requestStop()
            XCTAssertEqual(stopped.value, 0)
            f.makeGate.open()
            guard case .unavailable = await started.value else {
                XCTFail("Stop lost to startup"); throw ObserverTestFailure()
            }
            await stopping.value
            XCTAssertEqual(f.port.joinCount, 1)
        } catch { f.makeGate.open(); await f.finish(); _ = await started.value; throw error }
        await f.finish()
    }

    func testStopDuringStartupAndConcurrentStopsJoinActualPortRetirement() async throws {
        let f = ObserverFixture(blockStart: true, blockJoin: true)
        let started = Task { await f.observer.start() }
        let stopped = ActivityCounter()
        do {
            try await observerEventually { f.port.startEntered }
            let first = Task { await f.observer.stopAndJoin(); stopped.increment() }
            let second = Task { await f.observer.stopAndJoin(); stopped.increment() }
            try await observerEventually { f.port.stopWasRequested }
            f.startGate.open()
            try await observerEventually { f.port.joinEntered }
            XCTAssertEqual(stopped.value, 0, "Stop must not finish while native join is blocked")
            f.joinGate.open()
            _ = await (first.value, second.value)
            guard case .unavailable = await started.value else {
                XCTFail("Stopped startup published ready"); throw ObserverTestFailure()
            }
            XCTAssertEqual(stopped.value, 2)
            XCTAssertEqual(f.port.joinCount, 1)
        } catch { await f.finish(); _ = await started.value; throw error }
        await f.finish()
    }

    func testNativeMouseFactsMatchPositionButtonFlagsAndClickState() async throws {
        try await withFixture { f in
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                                              mouseCursorPosition: .init(x: -4, y: 9), mouseButton: .right))
            event.flags = .maskCommand
            event.setIntegerValueField(.mouseEventButtonNumber, value: 1)
            event.setIntegerValueField(.mouseEventClickState, value: 2)
            let registration = try f.observer.register(ticket: f.ticket(), expected: .init(type: .rightMouseDown,
                flags: .maskCommand, button: 1, clickState: 2, location: .init(x: -4, y: 9)))
            let stamped = try XCTUnwrap(f.observer.stampedCopy(of: event, for: registration))
            f.port.emit(stamped)
            guard case let .seen(seen) = await f.observer.wait(for: registration) else { return XCTFail("Mouse did not match") }
            XCTAssertEqual(seen.location, .init(.init(x: -4, y: 9)))
        }
    }

    private func withFixture(maxEvents: Int = 512, body: (ObserverFixture) async throws -> Void) async throws {
        let fixture = ObserverFixture(maxEvents: maxEvents)
        do { try await fixture.start(); try await body(fixture) }
        catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}

private final class ObserverFixture: @unchecked Sendable {
    let makeGate = ObserverBlockingGate()
    let startGate = ObserverBlockingGate()
    let joinGate = ObserverBlockingGate()
    let activity = ActivityCounter()
    let platform: FakePlatform
    let port: FakePort
    let observer: NativeEventObserver
    let operation = UUID()
    let target = NativeControlTargetBinding(processGeneration: 1, windowGeneration: 1, sessionGeneration: 1)
    let scope = NativeControlScopeBinding(sourceID: UUID(), generation: 1)
    let facts = NativeEventFacts(type: .keyDown, flags: .maskShift, keyCode: 0)
    init(maxEvents: Int = 512,
         state: NativeEventPortState = .ready(eventsOfInterest: NativeEventObserver.requiredEventsOfInterest, enabled: true),
         blockMake: Bool = false, blockStart: Bool = false, blockJoin: Bool = false) {
        if !blockMake { makeGate.open() }; if !blockStart { startGate.open() }; if !blockJoin { joinGate.open() }
        port = FakePort(state: state, startGate: startGate, joinGate: joinGate)
        platform = FakePlatform(port: port, makeGate: makeGate)
        observer = NativeEventObserver(platform: platform, maxEvents: maxEvents, activity: { [activity] in activity.increment() })
    }
    func start() async throws {
        guard case .available = await observer.start() else { throw ObserverTestFailure() }
    }
    func finish() async {
        makeGate.open(); startGate.open(); joinGate.open()
        await observer.stopAndJoin()
        XCTAssertFalse(makeGate.timedOut || startGate.timedOut || joinGate.timedOut, "test watchdog was needed")
    }
    func ticket(ordinal: Int = 0) -> NativeInputEventTicket {
        .init(operationID: operation, target: target, scope: scope, eventOrdinal: ordinal, sequence: UInt64(ordinal + 1))
    }
    func register(ordinal: Int = 0) throws -> NativeStreamRegistration { try observer.register(ticket: ticket(ordinal: ordinal), expected: facts) }
    func event() throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.flags = .maskShift; event.setIntegerValueField(.eventSourceUserData, value: 0)
        return event
    }
}

private final class FakePlatform: @unchecked Sendable, NativeEventObserverPlatform {
    let port: FakePort
    let makeGate: ObserverBlockingGate
    private let entered = ActivityCounter()
    var makeEntered: Bool { entered.value > 0 }
    init(port: FakePort, makeGate: ObserverBlockingGate) { self.port = port; self.makeGate = makeGate }
    func makePort(eventsOfInterest: CGEventMask, callback: @escaping @Sendable (CGEventType, CGEvent?) -> Void) throws -> any NativeEventObserverPort {
        entered.increment()
        guard makeGate.wait() else { throw ObserverTestFailure() }
        port.setCallback(callback)
        return port
    }
}
private final class FakePort: @unchecked Sendable, NativeEventObserverPort {
    private let lock = NSLock()
    private var state: NativeEventPortState
    private var callback: (@Sendable (CGEventType, CGEvent?) -> Void)?
    private var stopped = false
    private var started = false
    private var joining = false
    private var joined = 0
    let startGate: ObserverBlockingGate
    let joinGate: ObserverBlockingGate
    var stopWasRequested: Bool { lock.withLock { stopped } }
    var startEntered: Bool { lock.withLock { started } }
    var joinEntered: Bool { lock.withLock { joining } }
    var joinCount: Int { lock.withLock { joined } }
    init(state: NativeEventPortState, startGate: ObserverBlockingGate, joinGate: ObserverBlockingGate) {
        self.state = state; self.startGate = startGate; self.joinGate = joinGate
    }
    func setCallback(_ value: @escaping @Sendable (CGEventType, CGEvent?) -> Void) { lock.withLock { callback = value } }
    func setHealth(_ value: NativeEventPortState) { lock.withLock { state = value } }
    func emit(_ event: CGEvent?, type: CGEventType? = nil) {
        let callback = lock.withLock { self.callback }
        callback?(type ?? event?.type ?? .null, event)
    }
    func start() -> NativeEventPortState {
        lock.withLock { started = true }
        guard startGate.wait() else { return .unavailable("test start deadline") }
        return lock.withLock { stopped ? .unavailable("stopped") : state }
    }
    func health() -> NativeEventPortState { lock.withLock { stopped ? .unavailable("stopped") : state } }
    func requestStop() { lock.withLock { stopped = true } }
    func stopAndJoin() {
        requestStop()
        lock.withLock { joining = true }
        _ = joinGate.wait()
        lock.withLock { if joined == 0 { joined = 1 } }
    }
}
private final class ActivityCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
private final class ObserverBlockingGate: @unchecked Sendable {
    private let condition = NSCondition(); private var openValue = false; private var timeout = false
    var timedOut: Bool { condition.withLock { timeout } }
    func open() { condition.lock(); openValue = true; condition.broadcast(); condition.unlock() }
    func wait() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while !openValue {
            if !condition.wait(until: deadline) { timeout = true; return false }
        }
        return true
    }
}
private final class ObserverAsyncGate: @unchecked Sendable {
    private let lock = NSLock(); private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { value in
            let ready = lock.withLock { if opened { return true }; continuation = value; return false }
            if ready { value.resume() }
        }
    }
    func open() {
        let value = lock.withLock { opened = true; let value = continuation; continuation = nil; return value }
        value?.resume()
    }
}
private final class StreamResults: @unchecked Sendable {
    private let lock = NSLock(); private var results: [NativeStreamResult] = []
    func append(_ result: NativeStreamResult) { lock.withLock { results.append(result) } }
    var count: Int { lock.withLock { results.count } }
    var seenCount: Int { lock.withLock { results.filter { if case .seen = $0 { return true }; return false }.count } }
    var unavailableCount: Int { lock.withLock { results.filter { if case .unavailable = $0 { return true }; return false }.count } }
}
private struct ObserverTestFailure: Error {}
private func observerEventually(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ObserverTestFailure()
}
