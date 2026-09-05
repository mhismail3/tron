import Darwin
import Foundation

struct ProcessResult: Equatable, Sendable {
    var exitCode: Int
    var stdout: String
    var stderr: String

    init(exitCode: Int, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// The caller must distinguish disposable observation from an already accepted
/// operation. UI cancellation is not authority to abort registration/bootout.
enum Subprocess {
    enum Policy: Sendable { case observation, acceptedOperation }
    static let maximumOutputBytes = 1_048_576

    static func run(executable: URL, arguments: [String], policy: Policy) async -> ProcessResult {
        let execution = SubprocessExecution(policy: policy)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: execution.run(executable: executable, arguments: arguments))
                }
            }
        } onCancel: {
            execution.cancelObservation()
        }
    }
}

/// One lane owns the child and all reads. Cancellation/termination only wake
/// that lane; they never race a read by closing its descriptors from elsewhere.
private final class SubprocessExecution: @unchecked Sendable {
    private let policy: Subprocess.Policy
    private let lock = NSLock()
    private var cancelled = false
    private var wakeWriter: FileHandle?

    init(policy: Subprocess.Policy) { self.policy = policy }

    func cancelObservation() {
        guard policy == .observation else { return }
        lock.withLock { cancelled = true; wakeLocked() }
    }

    private func wake() { lock.withLock { wakeLocked() } }

    private func wakeLocked() {
        guard let wakeWriter else { return }
        var byte: UInt8 = 1
        // Nonblocking: a full pipe already contains the wakeup we need.
        _ = Darwin.write(wakeWriter.fileDescriptor, &byte, 1)
    }

    func run(executable: URL, arguments: [String]) -> ProcessResult {
        func failure(_ message: String) -> ProcessResult {
            ProcessResult(exitCode: -1, stdout: "", stderr: message)
        }
        if lock.withLock({ cancelled }) { return failure("Command cancelled.") }
        let deadline = policy == .observation ? (DispatchTime.now() + .seconds(5)).uptimeNanoseconds : nil
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe(), wakeup = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let readers = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        let writers = [stdout.fileHandleForWriting, stderr.fileHandleForWriting]
        var readerOpen = [true, true]
        var writersOpen = true
        var launched = false

        defer {
            if launched && process.isRunning {
                if policy == .observation {
                    // Only this owned read-only client is retired, never a
                    // service it queried or an unowned descendant/process group.
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
            process.terminationHandler = nil
            // Disable/close the writer under the same lock used by wakeups,
            // before closing the reader: no late write or SIGPIPE is possible.
            lock.withLock { wakeWriter = nil; try? wakeup.fileHandleForWriting.close() }
            try? wakeup.fileHandleForReading.close()
            for index in 0..<2 where readerOpen[index] { try? readers[index].close() }
            if writersOpen { for writer in writers { try? writer.close() } }
        }

        do {
            for handle in readers + writers + [wakeup.fileHandleForReading, wakeup.fileHandleForWriting] {
                let fd = handle.fileDescriptor
                guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { throw POSIXError(.EIO) }
            }
            for handle in readers + [wakeup.fileHandleForReading, wakeup.fileHandleForWriting] {
                let fd = handle.fileDescriptor
                let flags = fcntl(fd, F_GETFL)
                guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { throw POSIXError(.EIO) }
            }
            lock.withLock { wakeWriter = wakeup.fileHandleForWriting }
            process.terminationHandler = { [weak self] _ in self?.wake() }
            if lock.withLock({ cancelled }) { return failure("Command cancelled.") }
            try process.run()
            launched = true
            for writer in writers { try? writer.close() }
            writersOpen = false
        } catch {
            return failure(error.localizedDescription)
        }

        var output = [Data(), Data()]
        var captureFailure: String?
        var drainDeadline: UInt64?
        var bytes = [UInt8](repeating: 0, count: 16_384)
        func completedResult(_ captureFailure: String?) -> ProcessResult {
            if policy == .observation {
                if let captureFailure { return failure(captureFailure) }
                guard let stdout = String(data: output[0], encoding: .utf8),
                      let stderr = String(data: output[1], encoding: .utf8) else {
                    return failure("Command output was not UTF-8.")
                }
                return ProcessResult(exitCode: Int(process.terminationStatus), stdout: stdout, stderr: stderr)
            }
            // Accepted command status remains authoritative even if diagnostics
            // are incomplete. Never manufacture failure (and invite a retry) for
            // an operation that completed successfully.
            let note = captureFailure.map { "\n[\($0)]" } ?? ""
            return ProcessResult(
                exitCode: Int(process.terminationStatus),
                stdout: String(decoding: output[0], as: UTF8.self),
                stderr: String(decoding: output[1], as: UTF8.self) + note
            )
        }
        while true {
            if lock.withLock({ cancelled }) { return failure("Command cancelled.") }
            let now = DispatchTime.now().uptimeNanoseconds
            let exited = !process.isRunning
            if exited && !readerOpen.contains(true) {
                return completedResult(captureFailure)
            }
            if exited && drainDeadline == nil {
                // A descendant may retain a writer after our child exits. It
                // does not own an unbounded lifetime for this capture operation.
                drainDeadline = (DispatchTime.now() + .seconds(1)).uptimeNanoseconds
            }
            if let deadline, now >= deadline { return failure("Command timed out.") }
            if let drainDeadline, now >= drainDeadline {
                return completedResult("Command output did not close after exit.")
            }
            let end = [deadline, drainDeadline].compactMap { $0 }.min()
            let milliseconds = end.map { Int32(($0 - now + 999_999) / 1_000_000) } ?? -1
            var descriptors = readers.enumerated().map { index, handle in
                pollfd(fd: readerOpen[index] ? handle.fileDescriptor : -1, events: Int16(POLLIN), revents: 0)
            }
            descriptors.append(pollfd(fd: wakeup.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0))
            let ready = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), milliseconds) }
            if ready < 0 {
                if errno == EINTR { continue }
                return failure("Could not monitor command output.")
            }
            if descriptors[2].revents != 0 { _ = Darwin.read(descriptors[2].fd, &bytes, bytes.count) }
            for index in 0..<2 where readerOpen[index] && descriptors[index].revents != 0 {
                // One bounded read per stream lets exit/cancellation/deadline
                // processing run even while a child continuously writes.
                let count = Darwin.read(descriptors[index].fd, &bytes, bytes.count)
                if count > 0 {
                    let retained = min(count, Subprocess.maximumOutputBytes - output[index].count)
                    output[index].append(contentsOf: bytes.prefix(retained))
                    if retained < count {
                        let message = "Command output exceeded its limit."
                        if policy == .observation { return failure(message) }
                        captureFailure = message
                        // An accepted operation finishes; discard excess output
                        // instead of blocking its writer or pretending it is complete.
                    }
                } else if count == 0 {
                    try? readers[index].close()
                    readerOpen[index] = false
                } else if errno != EINTR && errno != EAGAIN {
                    captureFailure = "Could not read command output."
                    try? readers[index].close()
                    readerOpen[index] = false
                }
            }
        }
    }
}
