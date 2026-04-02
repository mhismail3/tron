import Foundation

enum AppConstants {
    static let defaultWorkspace = ""
    static let prodPort = "9847"
    static let defaultHost = "localhost"
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    static var fallbackServerURL: URL {
        guard let url = URL(string: "ws://\(defaultHost):\(prodPort)/ws") else {
            fatalError("Invalid WebSocket URL from constants: ws://\(defaultHost):\(prodPort)/ws")
        }
        return url
    }
}
