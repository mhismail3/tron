import Darwin
import Foundation
import Testing
@testable import TronMac

@Suite("SingleInstanceLock — file lock")
struct SingleInstanceLockTests {
    private enum ProbeError: Error { case unavailable, timedOut, unexpectedMarker(String) }

    private final class MarkerBox: @unchecked Sendable {
        var value: String?
    }

    private func probeURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TRON_SINGLE_INSTANCE_LOCK_PROBE"] else {
            throw ProbeError.unavailable
        }
        return URL(fileURLWithPath: path)
    }

    private func startProbe(_ executable: URL, lockPath: URL) throws -> (Process, Pipe, Pipe, DispatchSemaphore) {
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = [lockPath.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        return (process, input, output, finished)
    }

    private func readMarker(from pipe: Pipe, timeout: TimeInterval = 2) throws -> String {
        let finished = DispatchSemaphore(value: 0)
        let mutex = NSLock()
        let marker = MarkerBox()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            mutex.lock()
            marker.value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            mutex.unlock()
            finished.signal()
        }
        defer { handle.readabilityHandler = nil }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            throw ProbeError.timedOut
        }
        mutex.lock()
        defer { mutex.unlock() }
        guard let value = marker.value, !value.isEmpty else {
            throw ProbeError.unexpectedMarker("<empty>")
        }
        return value
    }

    private func waitForExit(_ process: Process, _ finished: DispatchSemaphore, timeout: TimeInterval = 2) throws {
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw ProbeError.timedOut
        }
    }

    private func cleanupProbe(
        _ process: Process,
        input: Pipe,
        finished: DispatchSemaphore
    ) {
        input.fileHandleForWriting.closeFile()
        guard process.isRunning else { return }
        process.terminate()
        _ = finished.wait(timeout: .now() + 2)
    }

    @Test("a second process is rejected while the owner holds the lock, then recovery succeeds")
    func crossProcessExclusionAndReleaseRecovery() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let lockPath = tmp.appendingPathComponent("test.lock", isDirectory: false)
        let executable = try probeURL()

        let (owner, ownerInput, ownerOutput, ownerFinished) = try startProbe(executable, lockPath: lockPath)
        defer { cleanupProbe(owner, input: ownerInput, finished: ownerFinished) }
        #expect(try readMarker(from: ownerOutput) == "acquired")

        let (contender, contenderInput, contenderOutput, contenderFinished) = try startProbe(executable, lockPath: lockPath)
        defer { cleanupProbe(contender, input: contenderInput, finished: contenderFinished) }
        contenderInput.fileHandleForWriting.closeFile()
        #expect(try readMarker(from: contenderOutput) == "rejected")
        try waitForExit(contender, contenderFinished)
        #expect(contender.terminationStatus != 0)

        ownerInput.fileHandleForWriting.closeFile()
        #expect(try readMarker(from: ownerOutput) == "released")
        try waitForExit(owner, ownerFinished)
        #expect(owner.terminationStatus == 0)

        let (recovered, recoveredInput, recoveredOutput, recoveredFinished) = try startProbe(executable, lockPath: lockPath)
        defer { cleanupProbe(recovered, input: recoveredInput, finished: recoveredFinished) }
        #expect(try readMarker(from: recoveredOutput) == "acquired")
        recoveredInput.fileHandleForWriting.closeFile()
        #expect(try readMarker(from: recoveredOutput) == "released")
        try waitForExit(recovered, recoveredFinished)
        #expect(recovered.terminationStatus == 0)
    }

    @Test("release after acquire is idempotent")
    func releaseIsIdempotent() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let lock = SingleInstanceLock(lockFileURL: tmp.appendingPathComponent("test.lock"))
        #expect(lock.acquire())
        lock.release()
        lock.release()
    }

    @Test("acquire creates the parent directory if missing")
    func acquireCreatesParent() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let nested = tmp.appendingPathComponent("a/b/c", isDirectory: true)
        let lockPath = nested.appendingPathComponent("test.lock", isDirectory: false)
        #expect(!FileManager.default.fileExists(atPath: nested.path))

        let lock = SingleInstanceLock(lockFileURL: lockPath)
        defer { lock.release() }
        #expect(lock.acquire())
        #expect(FileManager.default.fileExists(atPath: lockPath.path))
    }

    @Test("PID is written to the lock file")
    func pidWritten() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let lockPath = tmp.appendingPathComponent("test.lock", isDirectory: false)
        let lock = SingleInstanceLock(lockFileURL: lockPath)
        defer { lock.release() }
        #expect(lock.acquire())

        let body = try String(contentsOf: lockPath, encoding: .utf8)
        #expect(Int(body.trimmingCharacters(in: .whitespacesAndNewlines)) == Int(getpid()))
    }
}
