import Foundation
import AppKit

/// Glue between the `.tronMenuBarSendFeedback` notification and
/// `FeedbackComposer.present`. Isolated so AppDelegate stays small.
///
/// Flow:
/// 1. Resolve `tron` CLI binary path (same resolver the wizard uses).
/// 2. Run `tron logs --tail 200 --json`; capture stdout, parse
///    `[LogEntry]`.
/// 3. Read `CFBundleShortVersionString` + `CFBundleVersion` from the
///    running bundle.
/// 4. Hand everything to `FeedbackComposer.present`.
///
/// Failure cases are logged via `NSLog` (the Mac wrapper doesn't
/// have a user-visible banner system yet — menu-bar items are too
/// transient for a proper toast). If log capture fails, the mail
/// still opens with an empty log section.
@MainActor
enum MenuBarFeedbackAction {
    static func present() async {
        let composer = FeedbackComposer(
            appVersion: bundleVersion(key: "CFBundleShortVersionString") ?? "0.0.0",
            buildNumber: bundleVersion(key: "CFBundleVersion") ?? "0"
        )

        let logs = await fetchRecentLogs()
        composer.present(userNotes: "", logs: logs)
    }

    // MARK: - Log fetch

    static func fetchRecentLogs(tronBinary: URL? = nil) async -> [FeedbackComposer.LogEntry] {
        guard let tron = tronBinary ?? resolveTronBinary() else {
            NSLog("[feedback] tron binary not found; skipping log attachment")
            return []
        }

        let result = await runProcess(
            executable: tron,
            arguments: ["logs", "--tail", String(FeedbackComposer.defaultLogTailLimit), "--json"]
        )

        guard result.exitCode == 0 else {
            NSLog("[feedback] tron logs failed with exit \(result.exitCode): \(result.stderr)")
            return []
        }

        return parseLogsJSON(result.stdout)
    }

    /// Parses newline-delimited JSON log entries emitted by
    /// `tron logs --json`. One entry per line; empty lines are skipped.
    /// Decoding failures drop the offending line (rest of the batch
    /// continues) so a single corrupt line doesn't empty the entire
    /// attachment.
    static func parseLogsJSON(_ stdout: String) -> [FeedbackComposer.LogEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [FeedbackComposer.LogEntry] = []
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let data = Data(line.utf8)
            if let entry = try? decoder.decode(FeedbackComposer.LogEntry.self, from: data) {
                entries.append(entry)
            }
        }
        return entries
    }

    // MARK: - Process runner

    private static func resolveTronBinary() -> URL? {
        // Preferred: `~/.local/bin/tron` symlink planted by `tron install`.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/tron"),
            URL(fileURLWithPath: "/usr/local/bin/tron"),
            URL(fileURLWithPath: "/opt/homebrew/bin/tron"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private static func runProcess(executable: URL, arguments: [String]) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: ProcessResult(
                        exitCode: Int(process.terminationStatus),
                        stdout: stdout,
                        stderr: stderr
                    ))
                } catch {
                    continuation.resume(returning: ProcessResult(
                        exitCode: -1,
                        stdout: "",
                        stderr: "process failed: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    // MARK: - Bundle helpers

    private static func bundleVersion(key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }
}
