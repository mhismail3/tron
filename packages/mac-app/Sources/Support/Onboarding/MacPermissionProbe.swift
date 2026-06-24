import Darwin
import Foundation

/// Fast, non-prompting TCC probes owned by the wrapper app.
///
/// The server is launched through the bundled `com.tron.server`
/// LaunchAgent with the wrapper bundle IDs in `AssociatedBundleIdentifiers`.
/// macOS therefore surfaces this permission under the responsible wrapper
/// app (`Tron.app` in Release, `TronMac.app` in Debug). Probing from this
/// process keeps the wizard, System Settings row, and launchd attribution
/// aligned without creating a disabled `Tron Server.app` entry.
enum MacPermissionProbe {
    enum FileProbeOutcome: Equatable {
        case readable
        case permissionDenied
        case unavailable
    }

    static func probeAll() async -> [Permission: PermissionStatus] {
        [.fullDiskAccess: await probe(.fullDiskAccess)]
    }

    static func probe(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .fullDiskAccess:
            await probeFullDiskAccess()
        }
    }

    static func classifyFullDiskAccess(
        tcc: FileProbeOutcome,
        mail: FileProbeOutcome,
        safari: FileProbeOutcome
    ) -> PermissionStatus {
        switch tcc {
        case .readable:
            return .granted
        case .permissionDenied:
            return .denied
        case .unavailable:
            break
        }

        switch (mail, safari) {
        case (.readable, _), (.unavailable, .readable):
            return .granted
        case (.permissionDenied, _), (.unavailable, .permissionDenied):
            return .denied
        case (.unavailable, .unavailable):
            return .probeUnavailable
        }
    }

    private static func probeFullDiskAccess() async -> PermissionStatus {
        await Task.detached(priority: .userInitiated) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let tcc = home
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
            let mail = home.appendingPathComponent("Library/Mail", isDirectory: true)
            let safari = home.appendingPathComponent("Library/Safari", isDirectory: true)

            return classifyFullDiskAccess(
                tcc: fileOutcome(at: tcc),
                mail: directoryOutcome(at: mail),
                safari: directoryOutcome(at: safari)
            )
        }.value
    }

    private static func fileOutcome(at url: URL) -> FileProbeOutcome {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd < 0 else {
            close(fd)
            return .readable
        }
        return outcomeForErrno(errno)
    }

    private static func directoryOutcome(at url: URL) -> FileProbeOutcome {
        guard let dir = opendir(url.path) else {
            return outcomeForErrno(errno)
        }
        closedir(dir)
        return .readable
    }

    private static func outcomeForErrno(_ value: Int32) -> FileProbeOutcome {
        switch value {
        case EACCES, EPERM:
            return .permissionDenied
        default:
            return .unavailable
        }
    }

}
