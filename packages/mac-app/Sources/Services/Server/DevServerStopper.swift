import Darwin
import Foundation

enum DevServerStopResult: Equatable, Sendable {
    case stopped
    case notActive
    case failed(String)
}

enum DevServerStopper {
    static let sigterm = Int32(SIGTERM)
    static let sigkill = Int32(SIGKILL)
    private static let waitPollNanoseconds: UInt64 = 100_000_000
    private static let waitPollAttempts = 20

    static func stop(
        port: Int,
        probe: @escaping @Sendable (Int) async -> ServerProcessInfo? = { await ServerProcessProbe.probe(port: $0) },
        signal: @escaping @Sendable (Int, Int32) -> Bool = sendSignal,
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) async -> DevServerStopResult {
        guard let process = await probe(port), process.isDevServer else {
            return .notActive
        }

        guard signal(process.pid, sigterm) else {
            return .failed("Could not stop dev server PID \(process.pid). Run `tron dev --stop` from a terminal.")
        }
        if await waitForDevServerToLeave(
            port: port,
            pid: process.pid,
            probe: probe,
            sleep: sleep
        ) {
            return .stopped
        }

        _ = signal(process.pid, sigkill)
        if await waitForDevServerToLeave(
            port: port,
            pid: process.pid,
            probe: probe,
            sleep: sleep
        ) {
            return .stopped
        }

        return .failed("Dev server did not stop. Stop it from the terminal running `tron dev`, or run `tron dev --stop`.")
    }

    private static func waitForDevServerToLeave(
        port: Int,
        pid: Int,
        probe: @escaping @Sendable (Int) async -> ServerProcessInfo?,
        sleep: @escaping @Sendable (UInt64) async -> Void
    ) async -> Bool {
        for _ in 0..<waitPollAttempts {
            await sleep(waitPollNanoseconds)
            guard let current = await probe(port) else { return true }
            if current.pid != pid || !current.isDevServer {
                return true
            }
        }
        return false
    }

    private static func sendSignal(pid: Int, signal: Int32) -> Bool {
        let result = Darwin.kill(pid_t(pid), signal)
        return result == 0 || errno == ESRCH
    }
}
