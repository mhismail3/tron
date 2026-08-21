import Foundation

/// Result type for `Subprocess.run`. Sendable-clean so it can cross actor
/// boundaries when callers await work spawned away from the MainActor.
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

private final class SubprocessDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ value: Data) {
        lock.lock(); data.append(value); lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

private final class SubprocessCompletionOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func finish(_ result: ProcessResult, continuation: CheckedContinuation<ProcessResult, Never>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        continuation.resume(returning: result)
    }
}

/// Lightweight subprocess runner shared across the wrapper.
enum Subprocess {
    static func run(executable: URL, arguments: [String]) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let outData = SubprocessDataBuffer()
            let errData = SubprocessDataBuffer()
            let completion = SubprocessCompletionOwner()
            let drainGroup = DispatchGroup()

            // Each descriptor gets one blocking read-to-end lane. No
            // readabilityHandler is installed, so a read can never race a
            // termination callback or another consumer of the same handle.
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                drainGroup.leave()
            }
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                drainGroup.leave()
            }

            // Install observation before run: a child that exits immediately
            // still triggers exactly one completion after both drain lanes EOF.
            process.terminationHandler = { proc in
                drainGroup.notify(queue: .global(qos: .utility)) {
                    completion.finish(
                        ProcessResult(
                            exitCode: Int(proc.terminationStatus),
                            stdout: String(data: outData.snapshot(), encoding: .utf8) ?? "",
                            stderr: String(data: errData.snapshot(), encoding: .utf8) ?? ""
                        ),
                        continuation: continuation
                    )
                }
            }

            do {
                try process.run()
                // The parent does not write to either descriptor. Closing its
                // copies guarantees EOF once the child closes its inherited
                // descriptors, including for a fast-exit child.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
            } catch {
                // No termination callback is promised when launch fails. Close
                // the writer copies so the already-running drain lanes finish.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                drainGroup.notify(queue: .global(qos: .utility)) {
                    completion.finish(
                        ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription),
                        continuation: continuation
                    )
                }
            }
        }
    }
}
