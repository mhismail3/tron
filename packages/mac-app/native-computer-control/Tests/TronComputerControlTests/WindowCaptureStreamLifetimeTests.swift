import Foundation
import XCTest
@testable import TronComputerControl

/// Runs the actual SCK adapter's retirement/control code, substituting only SDK
/// completions. No SCStream, permission probe, window or input is created.
final class WindowCaptureStreamLifetimeTests: XCTestCase {
    func testTerminalBeforeStopErrorWaiterCannotBeLost() async {
        let lifetime = WindowCaptureStreamLifetime()
        let removed = RetirementCounter()
        XCTAssertTrue(lifetime.beginStart())
        let result = await lifetime.stopAndJoin(stop: {
            XCTAssertTrue(lifetime.withCallback(terminal: true) { XCTAssertFalse($0) })
            throw RetirementTestError()
        }, removeOutput: { removed.increment() }, sampleQueue: DispatchQueue(label: "test.capture.early"))
        XCTAssertEqual(result, .joined)
        XCTAssertEqual(removed.value, 1)
        XCTAssertEqual(lifetime.retirementFailure, .stopFailed)
    }

    func testStopErrorRetainsRealWaiterUntilLateTerminalIncludingFailedStartup() async throws {
        // beginStart records an ATTEMPT, not native success. The same cleanup is
        // required when that start subsequently fails without terminal evidence.
        let lifetime = WindowCaptureStreamLifetime()
        let removed = RetirementCounter(), finished = RetirementCounter()
        XCTAssertTrue(lifetime.beginStart())
        let stopping = Task {
            let result = await lifetime.stopAndJoin(stop: { throw RetirementTestError() },
                removeOutput: { removed.increment() }, sampleQueue: DispatchQueue(label: "test.capture.late"))
            finished.increment()
            return result
        }
        do {
            try await retirementEventually { lifetime.retirementFailure == .stopFailed }
            XCTAssertEqual(removed.value, 0)
            XCTAssertEqual(finished.value, 0)
            XCTAssertFalse(lifetime.withCallback { _ in XCTFail("ordinary callback admitted after Stop") })
            XCTAssertTrue(lifetime.withCallback(terminal: true) { XCTAssertFalse($0) })
            let result = await stopping.value
            XCTAssertEqual(result, .joined)
            XCTAssertEqual(removed.value, 1)
        } catch {
            lifetime.withCallback(terminal: true) { _ in }
            _ = await stopping.value
            throw error
        }
    }

    func testCallbackAndSampleQueueWorkMustRetireBeforeJoin() async throws {
        // A delegate can already be admitted on another queue; a sample can also
        // still be queued before it even tries admission. Both paths must join.
        for admittedDelegate in [true, false] {
            let lifetime = WindowCaptureStreamLifetime()
            XCTAssertTrue(lifetime.beginStart())
            let sampleQueue = DispatchQueue(label: "test.capture.drain")
            let gate = RetirementBlockingGate()
            let entered = expectation(description: "callback or queued sample entered")
            let removed = expectation(description: "native output removal called")
            let forbidden = expectation(description: "join returned while callback work survived")
            forbidden.isInverted = true
            let queue = admittedDelegate ? DispatchQueue.global(qos: .utility) : sampleQueue
            queue.async {
                if admittedDelegate {
                    lifetime.withCallback { _ in entered.fulfill(); gate.wait() }
                } else {
                    entered.fulfill(); gate.wait()
                    lifetime.withCallback { _ in XCTFail("queued sample admitted after Stop") }
                }
            }
            await fulfillment(of: [entered], timeout: 2)
            let stopping = Task {
                let result = await lifetime.stopAndJoin(stop: {}, removeOutput: { removed.fulfill() }, sampleQueue: sampleQueue)
                if !gate.isOpen { forbidden.fulfill() }
                return result
            }
            await fulfillment(of: [removed], timeout: 2)
            await fulfillment(of: [forbidden], timeout: 0.1)
            gate.open()
            let result = await stopping.value
            XCTAssertEqual(result, .joined)
            XCTAssertFalse(gate.timedOut, "watchdog does not prove callback completion")
        }
    }

    func testFinalDrainSealsLateTerminalAdmission() async {
        let lifetime = WindowCaptureStreamLifetime()
        XCTAssertTrue(lifetime.beginStart())
        let result = await lifetime.stopAndJoin(stop: {}, removeOutput: {}, sampleQueue: DispatchQueue(label: "test.capture.seal"))
        XCTAssertEqual(result, .joined)
        let late = RetirementCounter()
        for _ in 0..<20 {
            XCTAssertFalse(lifetime.withCallback(terminal: true) { _ in late.increment() })
        }
        XCTAssertEqual(late.value, 0)
        XCTAssertFalse(lifetime.beginStart())
    }

    func testRemovalErrorIsActuallyHandledAndStillSealsCallbacks() async {
        let lifetime = WindowCaptureStreamLifetime()
        let stopCalls = RetirementCounter(), removalCalls = RetirementCounter()
        XCTAssertTrue(lifetime.beginStart())
        let result = await lifetime.stopAndJoin(stop: { stopCalls.increment() }, removeOutput: {
            removalCalls.increment()
            throw RetirementTestError()
        }, sampleQueue: DispatchQueue(label: "test.capture.removal"))
        XCTAssertEqual(result, .failed(.stopFailed))
        XCTAssertEqual(lifetime.retirementFailure, .stopFailed)
        XCTAssertEqual(stopCalls.value, 1); XCTAssertEqual(removalCalls.value, 1)
        XCTAssertFalse(lifetime.withCallback(terminal: true) { _ in XCTFail("late terminal admitted") })
    }

    func testAlreadyTerminatedOrNeverStartedSkipsNativeStopButRemovesOutput() async {
        for attempted in [true, false] {
            let lifetime = WindowCaptureStreamLifetime()
            let removed = RetirementCounter()
            if attempted {
                XCTAssertTrue(lifetime.beginStart())
                lifetime.withCallback(terminal: true) { XCTAssertTrue($0) }
            }
            let result = await lifetime.stopAndJoin(stop: { XCTFail("no live native start to stop") },
                removeOutput: { removed.increment() }, sampleQueue: DispatchQueue(label: "test.capture.no-start"))
            XCTAssertEqual(result, .joined)
            XCTAssertEqual(removed.value, 1)
            XCTAssertFalse(lifetime.beginStart())
        }
    }
}

private final class RetirementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class RetirementBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false, timeout = false
    var isOpen: Bool { condition.withLock { opened } }
    var timedOut: Bool { condition.withLock { timeout } }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !opened {
            if !condition.wait(until: deadline) { timeout = true; return }
        }
    }
    func open() { condition.lock(); opened = true; condition.broadcast(); condition.unlock() }
}
private struct RetirementTestError: Error {}
private func retirementEventually(_ ready: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < deadline {
        if ready() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw RetirementTestError()
}
