import Foundation
import Darwin
import XCTest
@testable import TronComputerControl

final class NativeControlInterlockTests: XCTestCase {
    func testUnarmedDropAndRepeatedRetirementReleaseExclusion() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        var lease: NativeControlInterlockLease? = try NativeControlInterlockRoot(rootURL: root).acquire()
        XCTAssertNotNil(lease)
        lease = nil
        let successor = try NativeControlInterlockRoot(rootURL: root).acquire()
        try successor.retire()
        try successor.retire()
        XCTAssertFalse(markerExists(root))
        try NativeControlInterlockRoot(rootURL: root).acquire().retire()
    }

    func testTrustedCleanRetirementRemovesExactBytesAndAllowsSuccessor() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let interlock = try NativeControlInterlockRoot(rootURL: root)
        let lease = try interlock.acquire()
        let identity = try lease.arm()
        XCTAssertEqual(try markerBytes(root), expectedBytes(identity))
        try lease.retireAfterTrustedNativeRelease()
        XCTAssertFalse(markerExists(root))
        try lease.retireAfterTrustedNativeRelease()
        try interlock.acquire().retire()
    }

    func testConcurrentRetirementJoinsAndDoesNotCloseASuccessorDescriptor() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let interlock = try NativeControlInterlockRoot(rootURL: root)
        let lease = try interlock.acquire()
        let finished = DispatchGroup()
        let errors = ErrorBox()
        for _ in 0..<8 {
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do { try lease.retire() } catch { errors.append(error) }
            }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(errors.isEmpty)
        let successor = try interlock.acquire()
        try lease.retire()
        XCTAssertThrowsError(try interlock.acquire()) { XCTAssertEqual($0 as? NativeControlInterlockError, .lockBusy) }
        try successor.retire()
    }

    func testIndependentProcessHoldsTheActualSwiftLease() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let probe = try launchProbe(root: root, mode: "hold-unarmed")
        defer { probe.stop() }
        XCTAssertEqual(probe.readyLine, "ready")
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: root).acquire()) {
            XCTAssertEqual($0 as? NativeControlInterlockError, .lockBusy)
        }
        XCTAssertFalse(markerExists(root))
    }

    func testNoMarkerCrashControlDemonstratesFlockAloneDoesNotQuarantine() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let probe = try launchProbe(root: root, mode: "crash-unarmed")
        defer { probe.stop() }
        try probe.waitForExit()
        XCTAssertEqual(probe.process.terminationStatus, 0)
        XCTAssertFalse(markerExists(root))
        // This deliberately bad crash design permits another owner after process death.
        try NativeControlInterlockRoot(rootURL: root).acquire().retire()
    }

    func testArmedCrashRetainsExactMarkerAndBlocksUntilMatchingRecovery() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let probe = try launchProbe(root: root, mode: "crash-armed")
        defer { probe.stop() }
        let identity = try NativeControlQuarantineIdentity(rawValue: probe.readyLine)
        try probe.waitForExit()
        XCTAssertEqual(probe.process.terminationStatus, 0)
        XCTAssertEqual(try markerBytes(root), expectedBytes(identity))
        let interlock = try NativeControlInterlockRoot(rootURL: root)
        XCTAssertThrowsError(try interlock.acquire()) { XCTAssertEqual($0 as? NativeControlInterlockError, .quarantinePresent) }
        XCTAssertEqual(try markerBytes(root), expectedBytes(identity))
        try interlock.recoverExpectedMarker(identity)
        XCTAssertFalse(markerExists(root))
        try interlock.acquire().retire()
    }

    func testArmedDropDoesNotPretendNativeRelease() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        var lease: NativeControlInterlockLease? = try NativeControlInterlockRoot(rootURL: root).acquire()
        let identity = try XCTUnwrap(lease).arm()
        lease = nil
        XCTAssertEqual(try markerBytes(root), expectedBytes(identity))
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: root).acquire()) {
            XCTAssertEqual($0 as? NativeControlInterlockError, .quarantinePresent)
        }
    }

    func testWrongRecoveryIdentityPreservesMarkerAndDoesNotStrandFlock() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let interlock = try NativeControlInterlockRoot(rootURL: root)
        let lease = try interlock.acquire()
        let identity = try lease.arm()
        try lease.retire() // Ordinary close deliberately leaves quarantine.
        XCTAssertThrowsError(try interlock.recoverExpectedMarker(.init())) {
            XCTAssertEqual($0 as? NativeControlInterlockError, .wrongQuarantineIdentity)
        }
        XCTAssertEqual(try markerBytes(root), expectedBytes(identity))
        try interlock.recoverExpectedMarker(identity)
        XCTAssertFalse(markerExists(root))
    }

    func testSameIdentityReplacementCannotBeClearedByTheOriginalLease() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let lease = try NativeControlInterlockRoot(rootURL: root).acquire()
        let identity = try lease.arm()
        let original = try markerStatus(root)
        // Keep the original inode allocated so the replacement cannot recycle it.
        try FileManager.default.moveItem(at: markerURL(root), to: root.appendingPathComponent("old-marker"))
        try writeMarker(root, expectedBytes(identity))
        XCTAssertNotEqual(try markerStatus(root).st_ino, original.st_ino)
        XCTAssertThrowsError(try lease.retireAfterTrustedNativeRelease()) {
            guard case .unsafeQuarantine = $0 as? NativeControlInterlockError else {
                return XCTFail("Expected replacement refusal, got \($0)")
            }
        }
        XCTAssertEqual(try markerBytes(root), expectedBytes(identity))
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: root).acquire()) {
            XCTAssertEqual($0 as? NativeControlInterlockError, .quarantinePresent)
        }
    }

    func testFreshRecoveryAdmitsCurrentSameIdentityReplacementUnderItsOwnLock() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let owner = try NativeControlInterlockRoot(rootURL: root).acquire()
        let identity = try owner.arm()
        let original = try markerStatus(root)
        try owner.retire()
        try FileManager.default.moveItem(at: markerURL(root), to: root.appendingPathComponent("original-marker"))
        try writeMarker(root, expectedBytes(identity))
        XCTAssertNotEqual(try markerStatus(root).st_ino, original.st_ino)
        XCTAssertEqual(try markerBytes(root), expectedBytes(identity))
        // Unlike the original lease's clean retirement, fresh recovery admits the
        // currently matching file under its own exclusive lock.
        try NativeControlInterlockRoot(rootURL: root).recoverExpectedMarker(identity)
        XCTAssertFalse(markerExists(root))
        try NativeControlInterlockRoot(rootURL: root).acquire().retire()
    }

    func testWrongIdentityReplacementSurvivesOldRecoveryAndRequiresItsOwnIdentity() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let owner = try NativeControlInterlockRoot(rootURL: root).acquire()
        let original = try owner.arm()
        try owner.retire()
        try FileManager.default.moveItem(at: markerURL(root), to: root.appendingPathComponent("original-marker"))
        let replacement = NativeControlQuarantineIdentity()
        try writeMarker(root, expectedBytes(replacement))
        let recovery = try NativeControlInterlockRoot(rootURL: root)
        XCTAssertThrowsError(try recovery.recoverExpectedMarker(original)) {
            XCTAssertEqual($0 as? NativeControlInterlockError, .wrongQuarantineIdentity)
        }
        XCTAssertEqual(try markerBytes(root), expectedBytes(replacement))
        try recovery.recoverExpectedMarker(replacement)
        XCTAssertFalse(markerExists(root))
    }

    func testLateCloseFailureIsReportedOnceWithoutRetryOrStrandedLock() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let fault = CloseFault(failing: ["lock"])
        let owner = try NativeControlInterlockRoot(rootURL: root, descriptorClose: fault.close)
        let lease = try owner.acquire()
        XCTAssertThrowsError(try lease.retire()) { XCTAssertTrue(String(describing: $0).contains("close owned lock")) }
        XCTAssertThrowsError(try lease.retire())
        XCTAssertEqual(fault.count("lock"), 1)
        try NativeControlInterlockRoot(rootURL: root).acquire().retire()
    }

    func testArmCloseFailurePreservesQuarantineAndReleasesLock() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let fault = CloseFault(failing: ["marker", "lock"])
        let owner = try NativeControlInterlockRoot(rootURL: root, descriptorClose: fault.close)
        let lease = try owner.acquire()
        XCTAssertThrowsError(try lease.arm()) {
            let error = String(describing: $0)
            XCTAssertTrue(error.contains("close owned marker"))
            XCTAssertTrue(error.contains("close owned lock"))
        }
        XCTAssertEqual(fault.count("marker"), 1)
        XCTAssertEqual(fault.count("lock"), 1)
        XCTAssertTrue(markerExists(root))
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: root).acquire()) {
            XCTAssertEqual($0 as? NativeControlInterlockError, .quarantinePresent)
        }
    }

    func testAcquisitionAndRecoveryPreservePrimaryAndCloseFailures() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        try writeMarker(root, Data("partial".utf8))
        let fault = CloseFault(failing: ["marker", "lock"])
        let owner = try NativeControlInterlockRoot(rootURL: root, descriptorClose: fault.close)
        XCTAssertThrowsError(try owner.acquire()) {
            let error = String(describing: $0)
            XCTAssertTrue(error.contains("malformed"))
            XCTAssertTrue(error.contains("close owned marker"))
            XCTAssertTrue(error.contains("close owned lock"))
        }
        let expected = NativeControlQuarantineIdentity()
        try writeMarker(root, expectedBytes(expected))
        XCTAssertThrowsError(try owner.recoverExpectedMarker(.init())) {
            XCTAssertTrue(String(describing: $0).contains("close owned"))
        }
        XCTAssertEqual(try markerBytes(root), expectedBytes(expected))
        try NativeControlInterlockRoot(rootURL: root).recoverExpectedMarker(expected)
    }

    func testRootAndLockValidationErrorsPreserveCloseFailure() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let fault = CloseFault(failing: ["root", "lock"])
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: root, descriptorClose: fault.close)) {
            XCTAssertTrue(String(describing: $0).contains("mode"))
            XCTAssertTrue(String(describing: $0).contains("close owned root"))
        }
        XCTAssertEqual(fault.count("root"), 1)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let lock = root.appendingPathComponent(NativeControlInterlockRoot.lockName)
        try Data("invalid".utf8).write(to: lock)
        XCTAssertEqual(chmod(lock.path, 0o600), 0)
        let owner = try NativeControlInterlockRoot(rootURL: root, descriptorClose: fault.close)
        XCTAssertThrowsError(try owner.acquire()) {
            XCTAssertTrue(String(describing: $0).contains("not empty"))
            XCTAssertTrue(String(describing: $0).contains("close owned lock"))
        }
        XCTAssertEqual(fault.count("lock"), 1)
    }

    func testDeinitAttemptsCloseOnceAndPreservesArmedQuarantineOnLateError() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let fault = CloseFault(failing: ["lock", "root"])
        var owner: NativeControlInterlockRoot? = try .init(rootURL: root, descriptorClose: fault.close)
        var lease: NativeControlInterlockLease? = try XCTUnwrap(owner).acquire()
        let identity = try XCTUnwrap(lease).arm()
        owner = nil // The lease keeps the root descriptor alive until its own teardown.
        XCTAssertEqual(fault.count("root"), 0)
        lease = nil
        XCTAssertEqual(fault.count("lock"), 1)
        XCTAssertEqual(fault.count("root"), 1)
        XCTAssertEqual(try markerBytes(root), expectedBytes(identity))
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: root).acquire()) {
            XCTAssertEqual($0 as? NativeControlInterlockError, .quarantinePresent)
        }
    }

    func testAbandonedLeaseCannotReportTrustedCleanRetirement() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let lease = try NativeControlInterlockRoot(rootURL: root).acquire()
        let identity = try lease.arm()
        try lease.retire()
        XCTAssertThrowsError(try lease.retireAfterTrustedNativeRelease()) {
            XCTAssertEqual($0 as? NativeControlInterlockError, .alreadyClosed)
        }
        XCTAssertEqual(try markerBytes(root), expectedBytes(identity))
    }

    func testMalformedOversizedLinkedAndUnsafeMarkersFailClosed() throws {
        try assertBadMarker { try self.writeMarker($0, Data("partial".utf8)) }
        try assertBadMarker { try self.writeMarker($0, Data(repeating: 65, count: 129)) }
        try assertBadMarker { root in
            try FileManager.default.createSymbolicLink(atPath: self.markerURL(root).path, withDestinationPath: "missing-target")
        }
        try assertBadMarker { root in
            try self.writeMarker(root, self.expectedBytes(.init()))
            try FileManager.default.linkItem(at: self.markerURL(root), to: root.appendingPathComponent("hardlink"))
        }
        try assertBadMarker { root in
            try self.writeMarker(root, self.expectedBytes(.init()))
            XCTAssertEqual(chmod(self.markerURL(root).path, 0o644), 0)
        }
        try assertBadMarker { root in XCTAssertEqual(mkfifo(self.markerURL(root).path, 0o600), 0) }
    }

    func testUnsafeLockEntriesRefuseWithoutBlocking() throws {
        for kind in ["symlink", "hardlink", "mode", "fifo", "nonempty"] {
            let root = try makeRoot()
            defer { removeRoot(root) }
            let lock = root.appendingPathComponent(NativeControlInterlockRoot.lockName)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(atPath: lock.path, withDestinationPath: "missing")
            case "fifo": XCTAssertEqual(mkfifo(lock.path, 0o600), 0)
            default:
                try Data((kind == "nonempty" ? "x" : "").utf8).write(to: lock)
                XCTAssertEqual(chmod(lock.path, kind == "mode" ? 0o644 : 0o600), 0)
                if kind == "hardlink" { try FileManager.default.linkItem(at: lock, to: root.appendingPathComponent("linked-lock")) }
            }
            XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: root).acquire(), kind)
        }
    }

    func testUnsafeRootsAndOutsideMarkerCannotEscapeTheSuppliedDirectory() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let outside = root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: markerURL(root), withDestinationURL: outside)
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: root).recoverExpectedMarker(.init()))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
        let link = root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: link))
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: root))
        XCTAssertThrowsError(try NativeControlInterlockRoot(rootURL: URL(string: "https://example.invalid")!))
    }

    func testArmFailurePreservesPartialMarkerButClosesItsLock() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let interlock = try NativeControlInterlockRoot(rootURL: root)
        let lease = try interlock.acquire()
        try writeMarker(root, Data("partial".utf8))
        XCTAssertThrowsError(try lease.arm())
        XCTAssertThrowsError(try lease.arm()) { XCTAssertEqual($0 as? NativeControlInterlockError, .alreadyClosed) }
        XCTAssertEqual(try markerBytes(root), Data("partial".utf8))
        XCTAssertThrowsError(try interlock.acquire()) { XCTAssertEqual($0 as? NativeControlInterlockError, .malformedQuarantine) }
    }

    func testProbeEarlyExitAndMissingReadinessAreBoundedFailures() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        XCTAssertThrowsError(try launchProbe(root: root, mode: "exit-before-ready", timeout: 2))
        XCTAssertThrowsError(try launchProbe(root: root, mode: "no-ready", timeout: 0.2))
        XCTAssertFalse(markerExists(root))
        try NativeControlInterlockRoot(rootURL: root).acquire().retire()
    }

    // Child-only path executes the actual Swift interlock. _exit intentionally skips
    // deinit for crash tests. No native input or production path is ever opened.
    func testProcessProbe() throws {
        guard let mode = ProcessInfo.processInfo.environment["TRON_INTERLOCK_PROBE_MODE"],
              let path = ProcessInfo.processInfo.environment["TRON_INTERLOCK_PROBE_ROOT"] else { return }
        let rootURL = URL(fileURLWithPath: path)
        guard ["hold-unarmed", "crash-unarmed", "crash-armed", "exit-before-ready", "no-ready"].contains(mode),
              rootURL.lastPathComponent.hasPrefix("tron-native-interlock-"),
              rootURL.deletingLastPathComponent().resolvingSymlinksInPath().path ==
                FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path else {
            throw ProbeFailure(message: "probe requires an explicitly owned temporary test root")
        }
        if mode == "exit-before-ready" { Darwin._exit(7) }
        let lease = try NativeControlInterlockRoot(rootURL: rootURL).acquire()
        try withExtendedLifetime(lease) {
            if mode == "no-ready" { while true { pause() } }
            let ready = mode == "crash-armed" ? try lease.arm().rawValue : "ready"
            FileHandle.standardOutput.write(Data(("TRON-INTERLOCK-READY " + ready + "\n").utf8))
            if mode == "crash-armed" || mode == "crash-unarmed" { Darwin._exit(0) }
            while true { pause() }
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tron-native-interlock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func removeRoot(_ root: URL) { try? FileManager.default.removeItem(at: root) }
    private func markerURL(_ root: URL) -> URL { root.appendingPathComponent(NativeControlInterlockRoot.markerName) }
    private func markerBytes(_ root: URL) throws -> Data { try Data(contentsOf: markerURL(root)) }
    private func expectedBytes(_ identity: NativeControlQuarantineIdentity) -> Data {
        Data(("tron-native-control-quarantine/v1/" + identity.rawValue).utf8)
    }
    private func markerStatus(_ root: URL) throws -> stat {
        var info = stat()
        guard lstat(markerURL(root).path, &info) == 0 else { throw ProbeFailure(message: "marker stat failed") }
        return info
    }
    private func markerExists(_ root: URL) -> Bool { (try? markerStatus(root)) != nil }
    private func writeMarker(_ root: URL, _ data: Data) throws {
        try data.write(to: markerURL(root))
        XCTAssertEqual(chmod(markerURL(root).path, 0o600), 0)
    }
    private func assertBadMarker(_ fixture: (URL) throws -> Void) throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        try fixture(root)
        let interlock = try NativeControlInterlockRoot(rootURL: root)
        XCTAssertThrowsError(try interlock.acquire()) { XCTAssertNotEqual($0 as? NativeControlInterlockError, .lockBusy) }
        XCTAssertTrue(markerExists(root))
        XCTAssertThrowsError(try interlock.recoverExpectedMarker(.init()))
        XCTAssertTrue(markerExists(root))
    }

    private func launchProbe(root: URL, mode: String, timeout: TimeInterval = 5) throws -> Probe {
        let probe = Probe()
        probe.process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.process.arguments = ["xctest", "-XCTest", "TronComputerControlTests.NativeControlInterlockTests/testProcessProbe",
                                   Bundle(for: Self.self).bundleURL.path]
        probe.process.environment = ProcessInfo.processInfo.environment.merging([
            "TRON_INTERLOCK_PROBE_MODE": mode, "TRON_INTERLOCK_PROBE_ROOT": root.path,
        ]) { _, new in new }
        probe.process.standardOutput = probe.pipe
        probe.process.standardError = probe.pipe
        probe.process.terminationHandler = { [ended = probe.ended] _ in ended.signal() }
        do {
            try probe.process.run()
            try probe.pipe.fileHandleForWriting.close()
            probe.readyLine = try probe.readReady(timeout: timeout)
            return probe
        } catch {
            probe.stop()
            throw error
        }
    }
}

private struct ProbeFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private final class Probe {
    let process = Process()
    let pipe = Pipe()
    let ended = DispatchSemaphore(value: 0)
    var readyLine = ""

    func readReady(timeout: TimeInterval) throws -> String {
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ProbeFailure(message: "probe pipe could not become nonblocking")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let polled = poll(&descriptor, 1, 25)
            if polled < 0, errno == EINTR { continue }
            guard polled >= 0 else { throw ProbeFailure(message: "probe poll failed") }
            if polled == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else {
                throw ProbeFailure(message: "probe ended before readiness: " + String(decoding: output, as: UTF8.self))
            }
            output.append(contentsOf: buffer.prefix(count))
            guard output.count <= 32_768 else { throw ProbeFailure(message: "probe output exceeded bound") }
            for line in String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
                let prefix = "TRON-INTERLOCK-READY "
                if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
            }
        }
        throw ProbeFailure(message: "probe readiness deadline: " + String(decoding: output, as: UTF8.self))
    }

    func waitForExit() throws {
        if process.isRunning, ended.wait(timeout: .now() + 3) != .success {
            stop()
            throw ProbeFailure(message: "owned probe did not exit before deadline")
        }
        guard !process.isRunning else { throw ProbeFailure(message: "probe exit not confirmed") }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            if ended.wait(timeout: .now() + 1) != .success, process.isRunning {
                // Only this directly spawned offline test child; never a process pattern/group.
                _ = kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 2)
            }
            XCTAssertFalse(process.isRunning, "owned test helper retirement is unconfirmed")
        }
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
    deinit { stop() }
}

// Models a late OS close error: the descriptor is actually consumed, then EIO is
// reported. Never simulate this by leaving a live descriptor and inviting retries.
private final class CloseFault: @unchecked Sendable {
    private let lock = NSLock()
    private let failing: Set<String>
    private var calls: [String: Int] = [:]
    init(failing: Set<String>) { self.failing = failing }
    func close(_ descriptor: Int32, _ kind: NativeControlInterlockRoot.DescriptorKind) -> Int32 {
        lock.lock()
        calls[kind.rawValue, default: 0] += 1
        lock.unlock()
        let result = Darwin.close(descriptor)
        guard result == 0, failing.contains(kind.rawValue) else { return result }
        errno = EIO
        return -1
    }
    func count(_ kind: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls[kind, default: 0]
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []
    func append(_ error: any Error) { lock.lock(); errors.append(String(describing: error)); lock.unlock() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return errors.isEmpty }
}
