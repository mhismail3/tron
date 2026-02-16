import Foundation

enum AppConstants {
    static let defaultWorkspace: String = {
        NSHomeDirectory() + "/Workspace"
    }()
    static let tsBetaPort = "8082"
    static let tsProdPort = "8080"
    static let agentRsPort = "9847"
    static let tronRsPort = "9091"
    static let defaultHost = "localhost"
    static let appVersion = "0.0.1"
    static var fallbackServerURL: URL {
        URL(string: "ws://\(defaultHost):\(tsBetaPort)/ws")!
    }
}
