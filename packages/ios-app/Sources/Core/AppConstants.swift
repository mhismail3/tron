import Foundation

enum AppConstants {
    static let defaultWorkspace: String = {
        NSHomeDirectory() + "/Workspace"
    }()
    static let prodPort = "9847"
    static let defaultHost = "localhost"
    static let appVersion = "0.0.1"
    static var fallbackServerURL: URL {
        guard let url = URL(string: "ws://\(defaultHost):\(prodPort)/ws") else {
            fatalError("Invalid WebSocket URL from constants: ws://\(defaultHost):\(prodPort)/ws")
        }
        return url
    }
}
