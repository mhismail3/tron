import Foundation

enum AppConstants {
    static let defaultWorkspace = ""
    static let prodPort = "9847"
    static let defaultHost = "localhost"
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    // Force-unwrap is safe: the inputs are compile-time constants. AppConstantsTests
    // verifies the URL parses; any edit that breaks it trips CI before ship.
    static let fallbackServerURL = URL(string: "ws://\(defaultHost):\(prodPort)/ws")!
}
