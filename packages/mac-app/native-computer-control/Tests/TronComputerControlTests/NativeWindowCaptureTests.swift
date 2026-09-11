import Foundation
import XCTest
@testable import TronComputerControl

/// Controlled lifecycle evidence only: these streams never invoke ScreenCaptureKit.
final class NativeWindowCaptureTests: XCTestCase {
    func testStopBeforeStartAndPreCancelledStartNeverCreateStream() async throws {
        for cancelled in [false, true] {
            let f = try CaptureFixture()
            if cancelled {
                let gate = CaptureAsyncGate()
                let task = Task { await gate.wait(); return await f.owner.start() }
                task.cancel(); gate.open()
                captureAssertEqual(await task.value, .unavailable(.stopped))
            } else {
                captureAssertEqual(await f.owner.stopAndJoin(), .joined)
                captureAssertEqual(await f.owner.start(), .unavailable(.stopped))
            }
            XCTAssertEqual(f.platform.makeCount, 0)
            await f.finish()
        }
    }

    func testAbsentGrantRejectsBeforeStreamConstruction() async throws {
        let f = try CaptureFixture()
        f.platform.setFailure(.permissionUnavailable)
        captureAssertEqual(await f.owner.start(), .unavailable(.permissionUnavailable))
        XCTAssertEqual(f.platform.makeCount, 0)
        await f.finish()
    }

    func testConstructionFailureIsTerminalWithoutFallback() async throws {
        let f = try CaptureFixture()
        f.platform.setMakeFailure(.sourceUnavailable)
        captureAssertEqual(await f.owner.start(), .unavailable(.sourceUnavailable))
        captureAssertEqual(await f.owner.start(), .unavailable(.sourceUnavailable))
        XCTAssertEqual(f.platform.makeCount, 1)
        XCTAssertEqual(f.stream.startCount, 0)
        await f.finish()
    }

    func testStopDuringCreationOwnsAndJoinsTheLateStream() async throws {
        let f = try CaptureFixture(blockMake: true, blockJoin: true)
        let startup = Task { await f.owner.start() }
        do {
            try await captureEventually { f.platform.makeCount == 1 }
            f.owner.requestStop()
            f.makeGate.open()
            try await captureEventually { f.stream.joinEntered }
            XCTAssertEqual(f.stream.startCount, 0)
            f.joinGate.open()
            captureAssertEqual(await startup.value, .unavailable(.stopped))
            captureAssertEqual(await f.owner.stopAndJoin(), .joined)
            XCTAssertEqual(f.stream.joinCount, 1)
        } catch { await f.finish(); _ = await startup.value; throw error }
        await f.finish()
    }

    func testStopDuringStartupAndConcurrentStopsWaitForNativeCallbackJoin() async throws {
        let f = try CaptureFixture(blockStart: true, blockJoin: true)
        let startup = Task { await f.owner.start() }
        let completions = CaptureCounter()
        var stops: [Task<NativeWindowCaptureJoin, Never>] = []
        do {
            try await captureEventually { f.stream.startCount == 1 }
            for _ in 0..<2 {
                stops.append(Task { let result = await f.owner.stopAndJoin(); completions.increment(); return result })
            }
            try await captureEventually { f.stream.stopRequested }
            XCTAssertFalse(f.stream.joinEntered, "native Stop must follow the actual start completion")
            f.startGate.open()
            try await captureEventually { f.stream.joinEntered }
            XCTAssertEqual(completions.value, 0, "callback retirement is still held")
            f.joinGate.open()
            for stop in stops { captureAssertEqual(await stop.value, .joined) }
            captureAssertEqual(await startup.value, .unavailable(.stopped))
            XCTAssertEqual(f.stream.joinCount, 1)
        } catch {
            await f.finish(); _ = await startup.value
            for stop in stops { _ = await stop.value }
            throw error
        }
        await f.finish()
    }

    func testCancelledStartupStillJoinsRatherThanAbandoningNativeStart() async throws {
        let f = try CaptureFixture(blockStart: true, blockJoin: true)
        let completed = CaptureCounter()
        let startup = Task { let result = await f.owner.start(); completed.increment(); return result }
        do {
            try await captureEventually { f.stream.startCount == 1 }
            startup.cancel()
            try await captureEventually { f.stream.stopRequested }
            f.startGate.open()
            try await captureEventually { f.stream.joinEntered }
            XCTAssertEqual(completed.value, 0)
            f.joinGate.open()
            captureAssertEqual(await startup.value, .unavailable(.stopped))
        } catch { await f.finish(); _ = await startup.value; throw error }
        await f.finish()
    }

    func testStartupErrorAndGrantLossAcrossStartupJoinTheExactStream() async throws {
        for error in [NativeWindowCaptureError.streamFailed, .permissionUnavailable, .processUnavailable] {
            let f = try CaptureFixture(blockStart: true)
            if error == .streamFailed { f.stream.startFailure = error }
            let startup = Task { await f.owner.start() }
            do {
                try await captureEventually { f.stream.startCount == 1 }
                if error != .streamFailed { f.platform.setFailure(error) }
                f.startGate.open()
                captureAssertEqual(await startup.value, .unavailable(error))
                XCTAssertEqual(f.stream.joinCount, 1)
                XCTAssertEqual(f.platform.makeCount, 1)
            } catch { await f.finish(); _ = await startup.value; throw error }
            await f.finish()
        }
    }

    func testEarlyStaticFrameIsRetainedButNotPublishedUntilStartupCompletes() async throws {
        let f = try CaptureFixture(blockStart: true)
        let startup = Task { await f.owner.start() }
        do {
            try await captureEventually { f.stream.startCount == 1 }
            f.stream.frame(1)
            XCTAssertThrowsError(try f.owner.takeLatestFrame(generation: UUID()))
            f.startGate.open()
            guard case let .available(generation) = await startup.value else { throw CaptureTestFailure() }
            XCTAssertEqual(try f.owner.takeLatestFrame(generation: generation)?.jpeg, Data([1]))
        } catch { await f.finish(); _ = await startup.value; throw error }
        await f.finish()
    }

    func testSlowConsumerSeesOnlyLatestFrameAndPullConsumesItOnce() async throws {
        try await withCapture { f, generation in
            for byte in UInt8(1)...200 { f.stream.frame(byte) }
            let frame = try XCTUnwrap(f.owner.takeLatestFrame(generation: generation))
            XCTAssertEqual(frame.jpeg, Data([200]))
            XCTAssertEqual(frame.sequence, 200)
            XCTAssertEqual(frame.generation, generation)
            XCTAssertNil(try f.owner.takeLatestFrame(generation: generation))
        }
    }

    func testForeignGenerationAndCallbacksAfterStopCannotRestoreFrames() async throws {
        try await withCapture { f, generation in
            f.owner.ingest(.frame(jpeg: Data([8]), width: 16, height: 16), generation: UUID())
            XCTAssertNil(try f.owner.takeLatestFrame(generation: generation))
            f.stream.frame(1)
            XCTAssertThrowsError(try f.owner.takeLatestFrame(generation: UUID()))
            XCTAssertEqual(try f.owner.takeLatestFrame(generation: generation)?.jpeg, Data([1]))
            captureAssertEqual(await f.owner.stopAndJoin(), .joined)
            f.stream.frame(2); f.stream.emit(.failed(.streamFailed))
            XCTAssertThrowsError(try f.owner.takeLatestFrame(generation: generation))
            captureAssertEqual(await f.owner.start(), .unavailable(.stopped))
        }
    }

    func testSourceLossRevocationAndProcessReplacementInvalidateBufferedFrameAndAutoJoin() async throws {
        for error in [NativeWindowCaptureError.sourceUnavailable, .permissionUnavailable, .processUnavailable, .streamFailed] {
            try await withCapture { f, generation in
                f.stream.frame(1)
                if error == .sourceUnavailable || error == .streamFailed { f.stream.emit(.failed(error)) }
                else { f.platform.setFailure(error); f.stream.frame(2) }
                try await captureEventually { f.stream.joinCount == 1 }
                XCTAssertThrowsError(try f.owner.takeLatestFrame(generation: generation)) {
                    XCTAssertEqual($0 as? NativeWindowCaptureError, error)
                }
                f.platform.setFailure(nil)
                f.stream.frame(3)
                captureAssertEqual(await f.owner.start(), .unavailable(error))
                XCTAssertEqual(f.platform.makeCount, 1)
            }
        }
    }

    func testPullRevalidatesPermissionEvenWithoutNewCallbacks() async throws {
        try await withCapture { f, generation in
            f.stream.frame(1)
            f.platform.setFailure(.permissionUnavailable)
            XCTAssertThrowsError(try f.owner.takeLatestFrame(generation: generation)) {
                XCTAssertEqual($0 as? NativeWindowCaptureError, .permissionUnavailable)
            }
            captureAssertEqual(await f.owner.stopAndJoin(), .joined)
        }
    }

    func testMalformedProducerFramesFailClosed() async throws {
        for output in [NativeWindowCaptureOutput.frame(jpeg: Data(), width: 16, height: 16),
                       .frame(jpeg: Data([1]), width: Int.max, height: 16),
                       .frame(jpeg: Data(repeating: 1, count: NativeWindowCaptureLimits.maximumEncodedBytes + 1), width: 16, height: 16)] {
            try await withCapture { f, generation in
                f.stream.emit(output)
                XCTAssertThrowsError(try f.owner.takeLatestFrame(generation: generation)) {
                    XCTAssertEqual($0 as? NativeWindowCaptureError, .malformedFrame)
                }
            }
        }
    }

    func testUncertainStopStaysPendingUntilLateTerminalEvidence() async throws {
        let f = try CaptureFixture(blockJoin: true)
        f.stream.reportRetirementFailure(.stopFailed)
        _ = await f.owner.start()
        let completed = CaptureCounter()
        let stopping = Task { let result = await f.owner.stopAndJoin(); completed.increment(); return result }
        do {
            try await captureEventually { f.stream.joinEntered }
            XCTAssertEqual(f.owner.retirementFailure, .stopFailed)
            XCTAssertEqual(completed.value, 0)
            f.joinGate.open() // Model the native terminal receipt, not a stop error.
            captureAssertEqual(await stopping.value, .joined)
            XCTAssertEqual(f.owner.retirementFailure, .stopFailed)
        } catch { await f.finish(); _ = await stopping.value; throw error }
        await f.finish()
    }

    func testAbandonmentTransfersExactStreamToActualJoinedRetirement() async throws {
        let make = CaptureBlockingGate(); make.open()
        let start = CaptureBlockingGate(); start.open()
        let terminal = CaptureBlockingGate()
        var stream: CaptureFakeStream? = .init(startGate: start, joinGate: terminal)
        weak var retained = stream
        var platform: CaptureFakePlatform? = .init(stream: stream!, makeGate: make)
        var owner: NativeWindowCapture? = .init(platform: platform!, limits: try .init(width: 16, height: 16))
        _ = await owner?.start()
        platform = nil; stream = nil; owner = nil
        do {
            try await captureEventually { retained?.joinEntered == true }
            XCTAssertTrue(retained?.stopRequested == true)
            XCTAssertEqual(retained?.joinCount, 0)
            terminal.open()
            try await captureEventually { retained == nil }
        } catch { terminal.open(); throw error }
        XCTAssertFalse(terminal.timedOut)
    }

    func testRetiredOrForeignPullDoesNotProbePlatform() async throws {
        try await withCapture { f, generation in
            var count = f.platform.validationCount
            XCTAssertThrowsError(try f.owner.takeLatestFrame(generation: UUID()))
            XCTAssertEqual(f.platform.validationCount, count)
            _ = await f.owner.stopAndJoin()
            count = f.platform.validationCount
            XCTAssertThrowsError(try f.owner.takeLatestFrame(generation: generation))
            XCTAssertEqual(f.platform.validationCount, count)
        }
    }

    func testFailedOutputRemovalIsNeverReportedAsQuiescenceOrRetried() async throws {
        let f = try CaptureFixture()
        f.stream.joinResult = .failed(.stopFailed)
        _ = await f.owner.start()
        captureAssertEqual(await f.owner.stopAndJoin(), .failed(.stopFailed))
        captureAssertEqual(await f.owner.stopAndJoin(), .failed(.stopFailed))
        XCTAssertEqual(f.stream.joinCount, 1)
        captureAssertEqual(await f.owner.start(), .unavailable(.stopped))
        await f.finish()
    }

    private func withCapture(_ body: (CaptureFixture, UUID) async throws -> Void) async throws {
        let f = try CaptureFixture()
        do {
            guard case let .available(generation) = await f.owner.start() else { throw CaptureTestFailure() }
            try await body(f, generation)
        } catch { await f.finish(); throw error }
        await f.finish()
    }
}

private final class CaptureFixture: @unchecked Sendable {
    let makeGate = CaptureBlockingGate()
    let startGate = CaptureBlockingGate()
    let joinGate = CaptureBlockingGate()
    let stream: CaptureFakeStream
    let platform: CaptureFakePlatform
    let owner: NativeWindowCapture
    init(blockMake: Bool = false, blockStart: Bool = false, blockJoin: Bool = false) throws {
        if !blockMake { makeGate.open() }; if !blockStart { startGate.open() }; if !blockJoin { joinGate.open() }
        stream = CaptureFakeStream(startGate: startGate, joinGate: joinGate)
        platform = CaptureFakePlatform(stream: stream, makeGate: makeGate)
        owner = NativeWindowCapture(platform: platform, limits: try .init(width: 16, height: 16))
    }
    func finish() async {
        makeGate.open(); startGate.open(); joinGate.open()
        _ = await owner.stopAndJoin()
        XCTAssertFalse(makeGate.timedOut || startGate.timedOut || joinGate.timedOut, "test watchdog was needed")
    }
}
private final class CaptureFakePlatform: NativeWindowCapturePlatform, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: NativeWindowCaptureError?
    private var makeFailure: NativeWindowCaptureError?
    private var made = 0, validations = 0
    var validationCount: Int { lock.withLock { validations } }
    let stream: CaptureFakeStream
    let makeGate: CaptureBlockingGate
    init(stream: CaptureFakeStream, makeGate: CaptureBlockingGate) { self.stream = stream; self.makeGate = makeGate }
    var makeCount: Int { lock.withLock { made } }
    func setFailure(_ error: NativeWindowCaptureError?) { lock.withLock { failure = error } }
    func setMakeFailure(_ error: NativeWindowCaptureError) { lock.withLock { makeFailure = error } }
    func validate() throws {
        if let error = lock.withLock({ validations += 1; return failure }) { throw error }
    }
    func makeStream(limits: NativeWindowCaptureLimits, output: @escaping @Sendable (NativeWindowCaptureOutput) -> Void) throws -> any NativeWindowCaptureStream {
        lock.withLock { made += 1 }
        guard makeGate.wait() else { throw CaptureTestFailure() }
        if let error = lock.withLock({ makeFailure }) { throw error }
        stream.install(output)
        return stream
    }
}
private final class CaptureFakeStream: NativeWindowCaptureStream, @unchecked Sendable {
    private let lock = NSLock()
    private var output: (@Sendable (NativeWindowCaptureOutput) -> Void)?
    private var starts = 0, joins = 0
    private var stopping = false, joining = false
    private var startError: NativeWindowCaptureError?
    private var stopResult = NativeWindowCaptureJoin.joined
    private var stopError: NativeWindowCaptureError?
    var retirementFailure: NativeWindowCaptureError? { lock.withLock { stopError } }
    func reportRetirementFailure(_ error: NativeWindowCaptureError) { lock.withLock { stopError = error } }
    let startGate: CaptureBlockingGate
    let joinGate: CaptureBlockingGate
    var startFailure: NativeWindowCaptureError? {
        get { lock.withLock { startError } }
        set { lock.withLock { startError = newValue } }
    }
    var joinResult: NativeWindowCaptureJoin {
        get { lock.withLock { stopResult } }
        set { lock.withLock { stopResult = newValue } }
    }
    var startCount: Int { lock.withLock { starts } }
    var joinCount: Int { lock.withLock { joins } }
    var stopRequested: Bool { lock.withLock { stopping } }
    var joinEntered: Bool { lock.withLock { joining } }
    init(startGate: CaptureBlockingGate, joinGate: CaptureBlockingGate) { self.startGate = startGate; self.joinGate = joinGate }
    func install(_ callback: @escaping @Sendable (NativeWindowCaptureOutput) -> Void) { lock.withLock { output = callback } }
    func emit(_ value: NativeWindowCaptureOutput) { lock.withLock { output }?(value) }
    func frame(_ byte: UInt8) { emit(.frame(jpeg: Data([byte]), width: 16, height: 16)) }
    func start() async throws {
        lock.withLock { starts += 1 }
        guard startGate.wait() else { throw CaptureTestFailure() }
        if let error = startFailure { throw error }
    }
    func requestStop() { lock.withLock { stopping = true } }
    func stopAndJoin() async -> NativeWindowCaptureJoin {
        requestStop(); lock.withLock { joining = true }
        _ = joinGate.wait()
        return lock.withLock { joins += 1; return stopResult }
    }
}
private final class CaptureCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class CaptureBlockingGate: @unchecked Sendable {
    private let condition = NSCondition(); private var opened = false, timeout = false
    var timedOut: Bool { condition.withLock { timeout } }
    func open() { condition.lock(); opened = true; condition.broadcast(); condition.unlock() }
    func wait() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while !opened {
            if !condition.wait(until: deadline) { timeout = true; return false }
        }
        return true
    }
}
private final class CaptureAsyncGate: @unchecked Sendable {
    private let lock = NSLock(); private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { value in
            let ready = lock.withLock { if opened { return true }; continuation = value; return false }
            if ready { value.resume() }
        }
    }
    func open() {
        let pending = lock.withLock { opened = true; let pending = continuation; continuation = nil; return pending }
        pending?.resume()
    }
}
private struct CaptureTestFailure: Error {}
private func captureEventually(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw CaptureTestFailure()
}

private func captureAssertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}
