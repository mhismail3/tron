import Foundation

/// Client for server-owned Codex App Server lifecycle discovery.
///
/// This does not proxy Codex thread traffic. It only asks the active Tron
/// server for the managed `codex app-server` endpoint/token, then Codex mode
/// connects directly to that endpoint.
final class CodexAppServerClient: RPCDomainClient {
    func status() async throws -> CodexAppServerStatusResult {
        let ws = try requireTransport().requireConnection()
        return try await ws.send(
            method: "codexApp.status",
            params: EmptyParams()
        )
    }
}
