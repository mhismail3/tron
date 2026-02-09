import Foundation

enum AppConstants {
    static let defaultWorkspace: String = {
        NSHomeDirectory() + "/Workspace"
    }()
    static let betaPort = "8082"
    static let prodPort = "8080"
    static let defaultHost = "localhost"
    static let appVersion = "0.0.1"
    static var fallbackServerURL: URL {
        URL(string: "ws://\(defaultHost):\(betaPort)/ws")!
    }
}
