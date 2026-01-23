import SwiftUI
import Combine

// MARK: - App State

// NOTE: Uses global `logger` from TronLogger.swift (TronLogger.shared)

// MARK: - Server Settings Notification

extension Notification.Name {
    /// Posted when server settings (host, port, TLS) change
    static let serverSettingsDidChange = Notification.Name("tron.serverSettingsDidChange")
}

/// Notification sent when server settings change
struct ServerSettingsChanged {
    let host: String
    let port: String
    let useTLS: Bool
    let serverOrigin: String
}

@MainActor
class AppState: ObservableObject {
    // Default to Beta (8082) for all builds
    private static let defaultPort = "8082"

    @AppStorage("serverHost") private var serverHost = "localhost"
    @AppStorage("serverPort") private var serverPort = AppState.defaultPort
    @AppStorage("useTLS") private var useTLS = false
    @AppStorage("workingDirectory") var workingDirectory = ""
    @AppStorage("defaultModel") var defaultModel = "claude-opus-4-5-20251101"

    private var _rpcClient: RPCClient?
    private var _skillStore: SkillStore?

    /// Publisher for server settings changes
    let serverSettingsChanged = PassthroughSubject<ServerSettingsChanged, Never>()

    var rpcClient: RPCClient {
        if let client = _rpcClient {
            return client
        }
        let client = RPCClient(serverURL: serverURL)
        _rpcClient = client
        return client
    }

    var skillStore: SkillStore {
        if let store = _skillStore {
            return store
        }
        let store = SkillStore()
        store.configure(rpcClient: rpcClient)
        _skillStore = store
        return store
    }

    /// Default fallback URL when user-provided settings are invalid
    private static let fallbackURL = URL(string: "ws://localhost:8082/ws")!

    var serverURL: URL {
        let scheme = useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(serverHost):\(serverPort)/ws"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid server URL '\(urlString)', falling back to localhost", category: .general)
            return Self.fallbackURL
        }
        return url
    }

    var effectiveWorkingDirectory: String {
        if workingDirectory.isEmpty {
            return FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first?.path ?? "~"
        }
        return workingDirectory
    }

    func updateServerSettings(host: String, port: String, useTLS: Bool) {
        // Skip if nothing changed
        guard host != serverHost || port != serverPort || useTLS != self.useTLS else {
            logger.debug("Server settings unchanged, skipping update", category: .general)
            return
        }

        logger.info("Server settings changing: \(serverHost):\(serverPort) -> \(host):\(port)", category: .general)

        // Disconnect old client
        if let oldClient = _rpcClient {
            Task {
                await oldClient.disconnect()
            }
        }

        // Update stored settings
        serverHost = host
        serverPort = port
        self.useTLS = useTLS

        // Recreate client with new URL
        let newClient = RPCClient(serverURL: serverURL)
        _rpcClient = newClient

        // Update skill store with new client
        _skillStore?.configure(rpcClient: newClient)

        // Notify subscribers of the change
        let change = ServerSettingsChanged(
            host: host,
            port: port,
            useTLS: useTLS,
            serverOrigin: newClient.serverOrigin
        )
        serverSettingsChanged.send(change)

        // Also post via NotificationCenter for views that can't directly observe the publisher
        NotificationCenter.default.post(name: .serverSettingsDidChange, object: nil)

        logger.info("Server settings updated, new origin: \(newClient.serverOrigin)", category: .general)
    }

    /// Current server origin string (host:port)
    var currentServerOrigin: String {
        "\(serverHost):\(serverPort)"
    }
}
