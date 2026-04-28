import Foundation

/// Maps a `Permission` to the System Settings deep-link URL that reveals
/// its panel. Grant probing lives exclusively in the running agent.
enum PermissionDeepLink {
    static func url(for permission: Permission) -> URL {
        switch permission {
        case .fullDiskAccess:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}
