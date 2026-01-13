import SwiftUI

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @AppStorage("serverHost") private var serverHost = "localhost"
    @AppStorage("serverPort") private var serverPort = "8080"
    @AppStorage("useTLS") private var useTLS = false
    @AppStorage("workingDirectory") var workingDirectory = ""
    @AppStorage("defaultModel") var defaultModel = "claude-opus-4-5-20251101"

    private var _rpcClient: RPCClient?
    private var _skillStore: SkillStore?

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

    var serverURL: URL {
        let scheme = useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(serverHost):\(serverPort)/ws")!
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
        serverHost = host
        serverPort = port
        self.useTLS = useTLS

        // Recreate client with new URL
        let newClient = RPCClient(serverURL: serverURL)
        _rpcClient = newClient

        // Update skill store with new client
        _skillStore?.configure(rpcClient: newClient)
    }
}
