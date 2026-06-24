import Foundation

/// Client for system-level engine operations.
final class SystemClient: EngineDomainClient {

    func ping() async throws {
        _ = try requireTransport().requireConnection()

        let _: SystemPingResult = try await invokeRead(
            "system::ping",
            SystemPingParams(
                protocolVersion: 1,
                clientVersion: AppConstants.canonicalVersion
            )
        )
    }

    func getSystemInfo() async throws -> SystemInfoResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "system::get_info",
            EmptyParams()
        )
    }

}
