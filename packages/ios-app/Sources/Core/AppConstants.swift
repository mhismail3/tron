import Foundation

enum AppConstants {
    static let defaultWorkspace: String = {
        NSHomeDirectory() + "/Workspace"
    }()
    static let betaPort = "9846"
    static let prodPort = "9847"
    static let defaultHost = "localhost"
    static let appVersion = "0.0.1"
    static var fallbackServerURL: URL {
        URL(string: "ws://\(defaultHost):\(prodPort)/ws")!
    }
}
