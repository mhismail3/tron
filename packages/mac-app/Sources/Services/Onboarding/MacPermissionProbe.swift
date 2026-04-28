import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Fast, non-prompting TCC probes owned by the wrapper app.
///
/// The server is launched through the bundled `com.tron.server`
/// LaunchAgent with the wrapper bundle IDs in `AssociatedBundleIdentifiers`.
/// macOS therefore surfaces these permissions under the responsible wrapper
/// app (`Tron.app` in Release, `TronMac.app` in Debug). Probing from this
/// process keeps the wizard, System Settings rows, and launchd attribution
/// aligned without creating disabled `Tron Server.app` entries.
enum MacPermissionProbe {
    enum FileProbeOutcome: Equatable {
        case readable
        case permissionDenied
        case unavailable
    }

    enum ScreenRecordingProbeResult: String, Equatable {
        case granted
        case denied
        case unreadable
    }

    static func probeAll() async -> [Permission: PermissionStatus] {
        async let fullDiskAccess = probe(.fullDiskAccess)
        async let screenRecording = probe(.screenRecording)
        async let accessibility = probe(.accessibility)

        return await [
            .fullDiskAccess: fullDiskAccess,
            .screenRecording: screenRecording,
            .accessibility: accessibility,
        ]
    }

    static func probe(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .fullDiskAccess:
            await probeFullDiskAccess()
        case .screenRecording:
            await probeScreenRecording()
        case .accessibility:
            await probeAccessibility()
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

    static func classifyScreenRecording(
        preflightGranted: Bool,
        freshProbeResult: ScreenRecordingProbeResult
    ) -> PermissionStatus {
        if preflightGranted {
            return .granted
        }

        switch freshProbeResult {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .unreadable:
            return .probeUnavailable
        }
    }

    static func screenRecordingProbeResult(from text: String) -> ScreenRecordingProbeResult {
        ScreenRecordingProbeResult(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? .unreadable
    }

    static func screenRecordingPreflightGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func writeCurrentScreenRecordingProbeResult(to resultPath: String?) {
        let result: ScreenRecordingProbeResult = screenRecordingPreflightGranted() ? .granted : .denied
        let text = "\(result.rawValue)\n"

        if let resultPath, !resultPath.isEmpty {
            try? text.write(
                to: URL(fileURLWithPath: resultPath),
                atomically: true,
                encoding: .utf8
            )
        }

        if let data = text.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
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

    private static func probeScreenRecording() async -> PermissionStatus {
        await Task.detached(priority: .userInitiated) {
            let preflightGranted = screenRecordingPreflightGranted()
            return classifyScreenRecording(
                preflightGranted: preflightGranted,
                freshProbeResult: preflightGranted ? .granted : freshScreenRecordingProbe()
            )
        }.value
    }

    private static func probeAccessibility() async -> PermissionStatus {
        await Task.detached(priority: .userInitiated) {
            AXIsProcessTrusted() ? .granted : .denied
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

    private static func freshScreenRecordingProbe(
        executableURL: URL? = Bundle.main.executableURL,
        resultDirectory: URL = TronPaths.runDir,
        timeoutSeconds: TimeInterval = 6
    ) -> ScreenRecordingProbeResult {
        guard let executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .unreadable
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: resultDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return .unreadable
        }

        let resultURL = resultDirectory.appendingPathComponent(
            ".screen-recording-probe.\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: resultURL) }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            MacCommandLineMode.probeScreenRecordingAndQuitFlag,
            MacCommandLineMode.probeResultPathFlag,
            resultURL.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .unreadable
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard !process.isRunning else {
            process.terminate()
            return .unreadable
        }

        guard process.terminationStatus == 0,
              let text = try? String(contentsOf: resultURL, encoding: .utf8) else {
            return .unreadable
        }

        return screenRecordingProbeResult(from: text)
    }
}
