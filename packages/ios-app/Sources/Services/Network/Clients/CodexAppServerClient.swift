import Foundation

/// Client for server-owned Codex App Server lifecycle discovery.
///
/// This does not proxy Codex thread traffic. It only asks the active Tron
/// server for the managed `codex app-server` endpoint/token, then Codex mode
/// connects directly to that endpoint.
final class CodexAppServerClient: EngineDomainClient {
    func status() async throws -> CodexAppServerStatusResult {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "codex_app::status",
            EmptyParams()
        )
    }
}
