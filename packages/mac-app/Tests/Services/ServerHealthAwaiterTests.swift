import os
import Testing
@testable import TronMac

@Suite("ServerHealthAwaiter")
struct ServerHealthAwaiterTests {
    @Test("returns success as soon as ping reports healthy")
    func returnsSuccess() async {
        let calls = PingCallCounter(results: [
            .unreachable,
            .success(ServerInfo(version: "0.1.0-beta.7", port: 9847, paired: true)),
        ])

        let result = await ServerHealthAwaiter.waitForHealthy(
            token: "token",
            attempts: 5,
            delayNanoseconds: 0,
            pingServer: calls.ping
        )

        #expect(result.info?.version == "0.1.0-beta.7")
        #expect(calls.count == 2)
    }

    @Test("returns last failure after bounded attempts")
    func returnsLastFailure() async {
        let calls = PingCallCounter(results: [
            .unreachable,
            .timeout,
            .malformedResponse,
        ])

        let result = await ServerHealthAwaiter.waitForHealthy(
            token: nil,
            attempts: 3,
            delayNanoseconds: 0,
            pingServer: calls.ping
        )

        #expect(result == .malformedResponse)
        #expect(calls.count == 3)
    }
}

private final class PingCallCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let results: [ServerPingResult]

    init(results: [ServerPingResult]) {
        self.results = results
    }

    var count: Int {
        lock.withLock { $0.count }
    }

    func ping(_ token: String?) async -> ServerPingResult {
        lock.withLock {
            let index = min($0.count, results.count - 1)
            $0.count += 1
            return results[index]
        }
    }

    private struct State {
        var count = 0
    }
}
