import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Probes the three TCC permissions the wizard surfaces during the
/// Permissions step. None of the probes prompt - they only read current
/// state. Prompting happens via "Open System Settings" deep links.
enum PermissionProbe {
    static func probe(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .fullDiskAccess:
            return probeFullDiskAccess()
        case .accessibility:
            return probeAccessibility()
        case .screenRecording:
            return probeScreenRecording()
        }
    }

    // MARK: - Full Disk Access

    /// Heuristic: try to read `~/Library/Mail/V*` (which is FDA-protected
    /// on every modern macOS). If we can read the directory listing, FDA
    /// is granted. If we get EPERM, it's denied. If the path doesn't
    /// exist (e.g. user has never set up Mail), fall back to
    /// `~/Library/Application Support/com.apple.TCC/TCC.db` which is
    /// FDA-only.
    static func probeFullDiskAccess() -> PermissionStatus {
        let mailDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail", isDirectory: true)
        let tccDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db", isDirectory: false)

        for path in [mailDir, tccDB] {
            do {
                if FileManager.default.fileExists(atPath: path.path) {
                    if path.hasDirectoryPath {
                        _ = try FileManager.default.contentsOfDirectory(atPath: path.path)
                        return .granted
                    } else {
                        _ = try Data(contentsOf: path)
                        return .granted
                    }
                }
            } catch {
                // EPERM (operation not permitted) is the FDA denial signal.
                if (error as NSError).code == NSFileReadNoPermissionError ||
                   (error as NSError).code == 257 /* NSFileReadUnknownError */ {
                    return .denied
                }
                continue
            }
        }
        return .notDetermined
    }

    // MARK: - Accessibility

    /// `AXIsProcessTrusted` returns the synchronous grant state. We do
    /// NOT call `AXIsProcessTrustedWithOptions(prompt: true)` here -
    /// that would prompt the user and conflict with our "Open System
    /// Settings" UX.
    static func probeAccessibility() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    // MARK: - Screen Recording

    /// `CGPreflightScreenCaptureAccess()` returns the current grant
    /// state without prompting, matching the synchronous semantics of
    /// `AXIsProcessTrusted()` above. We intentionally avoid
    /// `CGRequestScreenCaptureAccess()` — that one prompts the first
    /// time and then flips the state permanently in TCC, which would
    /// race the "Open System Settings" deep-link UX we use everywhere
    /// else.
    ///
    /// TCC only distinguishes "granted" from "not granted" for Screen
    /// Recording, so we collapse `.notDetermined` and `.denied` both
    /// to `.denied` — the wizard treats either as "needs grant" and
    /// sends the user to the same Settings pane.
    static func probeScreenRecording() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }
}

/// Maps a `Permission` to the System Settings deep-link URL that
/// reveals its panel. Tests pin these strings.
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
