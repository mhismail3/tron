import Foundation

enum ServerHealthAwaiter {
    static func waitForHealthy(setup: EnvironmentSetup) async -> ServerPingResult {
        await waitForHealthy(
            token: setup.readBearerToken(),
            attempts: setup.serverStartHealthCheckAttempts,
            delayNanoseconds: setup.serverStartHealthCheckDelayNanoseconds,
            pingServer: setup.pingServer
        )
    }

    static func waitForHealthy(
        token: String?,
        attempts: Int,
        delayNanoseconds: UInt64,
        pingServer: @Sendable (String?) async -> ServerPingResult
    ) async -> ServerPingResult {
        let boundedAttempts = max(1, attempts)
        var lastResult: ServerPingResult = .unreachable

        for attempt in 0..<boundedAttempts {
            let result = await pingServer(token)
            if case .success = result {
                return result
            }
            lastResult = result

            if attempt + 1 < boundedAttempts, delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        return lastResult
    }
}
