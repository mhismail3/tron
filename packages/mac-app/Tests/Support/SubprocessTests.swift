import Darwin
import Foundation
import Testing
@testable import TronMac

struct SubprocessTests {
    @Test("a fast-exit child completes exactly once")
    func fastExit() async {
        let result = await observe(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 7"])
        #expect(result.exitCode == 7)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test("drains stdout and stderr while a noisy child is running")
    func drainsBothPipes() async {
        let result = await observe(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do printf o; printf e >&2; i=$((i+1)); done"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == String(repeating: "o", count: 20_000))
        #expect(result.stderr == String(repeating: "e", count: 20_000))
    }

    @Test("cancelled observation retires a TERM-ignoring child")
    func cancellationRetiresChild() async throws {
        let fixture = try SubprocessFixture()
        defer { fixture.stop() }
        let pending = Task { await observe(executable: fixture.shell, arguments: fixture.arguments) }
        let pid = await fixture.readyPID()
        #expect(pid != nil)
        let started = ContinuousClock.now
        pending.cancel()
        let result = await pending.value
        #expect(result.exitCode != 0)
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(!fixture.watchdogFired)
        if let pid { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
    }

    @Test("one deadline retires a hung observation")
    func timeoutRetiresChild() async throws {
        let fixture = try SubprocessFixture()
        defer { fixture.stop() }
        let started = ContinuousClock.now
        let pending = Task { await observe(executable: fixture.shell, arguments: fixture.arguments) }
        let pid = await fixture.readyPID()
        #expect(pid != nil)
        let result = await pending.value
        #expect(result.exitCode != 0)
        #expect(started.duration(to: .now) < .seconds(7))
        #expect(!fixture.watchdogFired)
        if let pid { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
    }

    @Test("exited child cannot leave capture waiting on inherited writers", arguments: [false, true])
    func inheritedWriterDoesNotStrandCapture(stderr: Bool) async throws {
        let fixture = try SubprocessFixture(inheritedWriter: true, stderr: stderr)
        defer { fixture.stop() }
        let started = ContinuousClock.now
        let result = await observe(executable: fixture.shell, arguments: fixture.arguments)
        #expect(result.exitCode != 0)
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(!fixture.watchdogFired)
        // The fixture, not the runner, owns this separate background holder.
        fixture.release()
        #expect(await fixture.waitForDone())
    }

    @Test("oversized observation output is not returned as success", arguments: [false, true])
    func oversizedOutputFails(stderr: Bool) async {
        let redirect = stderr ? " > \"/dev/stderr\"" : ""
        let result = await observe(
            executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i=0; i<1200000; i++) printf \"x\"\(redirect) }"]
        )
        #expect(result.exitCode != 0)
        #expect(result.stdout.utf8.count <= 1_048_576)
        #expect(result.stderr.utf8.count <= 1_048_576)
    }

    @Test("failed launch completes without leaking pending pipe readers")
    func failedLaunch() async {
        let result = await observe(executable: URL(fileURLWithPath: "/nonexistent-tron-test-\(UUID().uuidString)"), arguments: [])
        #expect(result.exitCode == -1)
        #expect(result.stdout.isEmpty)
        #expect(!result.stderr.isEmpty)
    }

    @Test("accepted command cancellation cannot undo its completion")
    func acceptedCancellationStillCompletes() async throws {
        let fixture = try SubprocessFixture()
        defer { fixture.stop() }
        let pending = Task {
            await Subprocess.run(executable: fixture.shell, arguments: fixture.arguments, policy: .acceptedOperation)
        }
        let pid = await fixture.readyPID()
        #expect(pid != nil)
        pending.cancel()
        fixture.release()
        let result = await pending.value
        #expect(result.exitCode == 0)
        #expect(result.stdout == "released")
        #expect(!fixture.watchdogFired)
        if let pid { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
    }

    @Test("accepted command retains exit status while excess diagnostics drain")
    func acceptedOutputLimit() async {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i=0; i<1200000; i++) printf \"x\" }"],
            policy: .acceptedOperation
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == String(repeating: "x", count: 1_048_576))
        #expect(result.stderr.contains("output exceeded"))
    }

    @Test("accepted child exit remains authoritative when a descendant retains output")
    func acceptedInheritedWriter() async throws {
        let fixture = try SubprocessFixture(inheritedWriter: true)
        defer { fixture.stop() }
        let started = ContinuousClock.now
        let result = await Subprocess.run(executable: fixture.shell, arguments: fixture.arguments, policy: .acceptedOperation)
        #expect(result.exitCode == 0)
        #expect(result.stderr.contains("did not close"))
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(!fixture.watchdogFired)
        fixture.release()
        #expect(await fixture.waitForDone())
    }

    @Test("invalid UTF-8 cannot masquerade as an empty successful observation")
    func invalidTextFailsClosed() async {
        let result = await observe(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '\\377'"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("UTF-8"))
    }

    @Test("pre-cancellation respects observation versus accepted admission", arguments: [Subprocess.Policy.observation, .acceptedOperation])
    func preCancelled(policy: Subprocess.Policy) async {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let marker = root.appendingPathComponent("executed")
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf executed > \"$1\"", "fixture", marker.path],
                policy: policy
            )
        }
        let result = await pending.value
        #expect((result.exitCode == 0) == (policy == .acceptedOperation))
        #expect(FileManager.default.fileExists(atPath: marker.path) == (policy == .acceptedOperation))
    }

    @Test("multibyte text survives pipe chunk boundaries exactly")
    func multibyteOutput() async {
        let result = await observe(
            executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { printf \"%16383s🙂%16383s\", \"\", \"\"; printf \"é\" > \"/dev/stderr\" }"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == String(repeating: " ", count: 16_383) + "🙂" + String(repeating: " ", count: 16_383))
        #expect(result.stderr == "é")
    }

    @Test("Tailscale selection still reaches a healthy owned CLI after ordinary failures")
    func tailscaleHealthyCandidate() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let scripts = ["exit 7", "printf malformed", "printf '%s' '{\"BackendState\":\"Running\",\"Self\":{\"TailscaleIPs\":[\"100.64.0.9\"]}}'"]
        var candidates: [URL] = []
        for (index, script) in scripts.enumerated() {
            let url = root.appendingPathComponent("candidate-\(index)")
            try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            candidates.append(url)
        }
        let status = await TailscaleProbe.probe(tailscaleAppExists: { _ in false }, cliPaths: candidates) { url in
            await observe(executable: url, arguments: ["status", "--peers=false", "--json"])
        }
        #expect(status == .signedIn(address: "100.64.0.9"))
    }

    @Test("cancelled Tailscale probe retires its real helper and stops candidate fallback")
    func tailscaleCancellation() async throws {
        let fixture = try SubprocessFixture()
        defer { fixture.stop() }
        let calls = ProbeCalls()
        let pending = Task {
            await TailscaleProbe.probe(tailscaleAppExists: { _ in false }, cliPaths: [fixture.shell, fixture.shell]) { url in
                await calls.record()
                return await observe(executable: url, arguments: fixture.arguments)
            }
        }
        let pid = await fixture.readyPID()
        #expect(pid != nil)
        let started = ContinuousClock.now
        pending.cancel()
        let status = await pending.value
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(status == .installedNotSignedIn)
        #expect(await calls.count == 1)
        #expect(!fixture.watchdogFired)
        if let pid { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
    }

    private func observe(executable: URL, arguments: [String]) async -> ProcessResult {
        await Subprocess.run(executable: executable, arguments: arguments, policy: .observation)
    }
}

/// FIFO readiness is emitted by the actual child before cancellation. The
/// watchdog releases only owned fixtures; it cannot satisfy boundedness tests.
private actor ProbeCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class SubprocessFixture: @unchecked Sendable {
    let shell: URL
    let root: URL
    let arguments: [String]
    private let lock = NSLock()
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "tron-subprocess-test")
    private let closed = DispatchGroup()
    private let events: AsyncStream<String>
    private let sink: AsyncStream<String>.Continuation
    private var releaseFD: Int32
    private var expired = false
    private var timer: DispatchWorkItem?

    var watchdogFired: Bool { lock.withLock { expired } }

    init(inheritedWriter: Bool = false, stderr: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tron-process-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var transferred = false
        var descriptors: [Int32] = []
        defer {
            if !transferred {
                for fd in descriptors where fd >= 0 { close(fd) }
                try? FileManager.default.removeItem(at: directory)
            }
        }
        root = directory
        let readyPath = root.appendingPathComponent("ready").path
        let releasePath = root.appendingPathComponent("release").path
        guard mkfifo(readyPath, 0o600) == 0, mkfifo(releasePath, 0o600) == 0 else {
            throw POSIXError(.EIO)
        }
        let readyFD = open(readyPath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        releaseFD = open(releasePath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        descriptors = [readyFD, releaseFD]
        guard readyFD >= 0, releaseFD >= 0 else { throw POSIXError(.EIO) }
        let script: String
        if inheritedWriter {
            // After the runner returns, the fixture releases this holder. A
            // failed write independently proves the runner's read end closed.
            let destination = stderr ? ">&2" : ""
            script = "(trap '' PIPE; read value < \"$1/release\"; if printf '%4096s' x \(destination) 2>/dev/null; then state=open; else state=done; fi; printf '%s\\n' \"$state\" > \"$1/ready\") & exit 0"
        } else {
            script = "trap '' TERM; printf '%s\\n' \"$$\" > \"$1/ready\"; read value < \"$1/release\"; printf released"
        }
        shell = root.appendingPathComponent("helper")
        try ("#!/bin/sh\n" + script + "\n").write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        arguments = [root.path]
        (events, sink) = AsyncStream.makeStream(of: String.self)
        source = DispatchSource.makeReadSource(fileDescriptor: readyFD, queue: queue)
        let output = sink
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = read(readyFD, &bytes, bytes.count)
            if count > 0 {
                for line in String(decoding: bytes.prefix(count), as: UTF8.self).split(separator: "\n") {
                    output.yield(String(line))
                }
            }
        }
        let closed = closed
        closed.enter()
        source.setCancelHandler { close(readyFD); closed.leave() }
        source.resume()
        transferred = true
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.expired = true }
            self.release()
            self.sink.finish()
        }
        timer = watchdog
        queue.asyncAfter(deadline: .now() + 8, execute: watchdog)
    }

    func readyPID() async -> Int32? {
        for await value in events { if let pid = Int32(value) { return pid } }
        return nil
    }

    func waitForDone() async -> Bool {
        for await value in events {
            #expect(value == "done", "Inherited writer still had a reader after capture returned: \(value)")
            return value == "done"
        }
        return false
    }

    func release() {
        lock.withLock {
            guard releaseFD >= 0 else { return }
            var newline: UInt8 = 10
            _ = write(releaseFD, &newline, 1)
        }
    }

    func stop() {
        release()
        timer?.cancel()
        source.cancel()
        #expect(closed.wait(timeout: .now() + 1) == .success)
        sink.finish()
        lock.withLock { if releaseFD >= 0 { close(releaseFD); releaseFD = -1 } }
        try? FileManager.default.removeItem(at: root)
    }
}
