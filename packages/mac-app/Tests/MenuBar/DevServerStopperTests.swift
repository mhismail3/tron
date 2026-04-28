import os
import Testing
@testable import TronMac

@Suite("DevServerStopper")
struct DevServerStopperTests {
    @Test("refuses to stop a non-dev port owner")
    func refusesNonDevProcess() async {
        let signals = SignalRecorder()
        let result = await DevServerStopper.stop(
            port: 9847,
            probe: { _ in
                ServerProcessInfo(pid: 12, uptime: nil, command: "tron --port 9847", isDevServer: false)
            },
            signal: { pid, sig in
                signals.append(pid: pid, signal: sig)
                return true
            },
            sleep: { _ in }
        )

        #expect(result == .notActive)
        #expect(signals.values.isEmpty)
    }

    @Test("terminates dev process and returns stopped once port is free")
    func terminatesDevProcess() async {
        let probes = ProbeCounter()
        let signals = SignalRecorder()
        let result = await DevServerStopper.stop(
            port: 9847,
            probe: { _ in
                if probes.next() == 1 {
                    return ServerProcessInfo(
                        pid: 24_680,
                        uptime: "00:00:09",
                        command: "/Users/example/.tron/system/run/Tron-Dev.app/Contents/MacOS/tron --port 9847",
                        isDevServer: true
                    )
                }
                return nil
            },
            signal: { pid, sig in
                signals.append(pid: pid, signal: sig)
                return true
            },
            sleep: { _ in }
        )

        #expect(result == .stopped)
        #expect(signals.values.count == 1)
        #expect(signals.values.first?.pid == 24_680)
        #expect(signals.values.first?.signal == DevServerStopper.sigterm)
    }

    @Test("escalates to kill when dev process keeps listening")
    func escalatesToKill() async {
        let signals = SignalRecorder()
        let result = await DevServerStopper.stop(
            port: 9847,
            probe: { _ in
                ServerProcessInfo(
                    pid: 24_680,
                    uptime: "00:00:09",
                    command: "/Users/example/.tron/system/run/Tron-Dev.app/Contents/MacOS/tron --port 9847",
                    isDevServer: true
                )
            },
            signal: { pid, sig in
                signals.append(pid: pid, signal: sig)
                return true
            },
            sleep: { _ in }
        )

        #expect(result == .failed("Dev server did not stop. Stop it from the terminal running `tron dev`, or run `tron dev --stop`."))
        #expect(signals.values.count == 2)
        #expect(signals.values.first?.pid == 24_680)
        #expect(signals.values.first?.signal == DevServerStopper.sigterm)
        #expect(signals.values.last?.pid == 24_680)
        #expect(signals.values.last?.signal == DevServerStopper.sigkill)
    }
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [(pid: Int, signal: Int32)]())

    var values: [(pid: Int, signal: Int32)] {
        lock.withLock { $0 }
    }

    func append(pid: Int, signal: Int32) {
        lock.withLock {
            $0.append((pid: pid, signal: signal))
        }
    }
}

private final class ProbeCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    func next() -> Int {
        lock.withLock {
            $0 += 1
            return $0
        }
    }
}
