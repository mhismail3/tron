import Foundation

/// Resolves the user-installed `tron` CLI binary across the canonical
/// install locations.
///
/// The Mac wrapper shells out to the CLI for several actions (logs, update
/// check, uninstall, feedback log capture) instead of duplicating those
/// code paths in Swift. Centralizing the lookup ensures the menu bar and
/// feedback action stay in lockstep — adding a new install location only
/// touches one file.
///
/// Returns `nil` when no candidate is executable. Callers must degrade
/// gracefully (e.g. open the GitHub Releases page when `self-update check`
/// can't run; surface a "tron CLI not found" error in the feedback log).
enum TronCLI {
    /// Search order:
    /// 1. `~/.local/bin/tron` — canonical, planted by `scripts/tron install`.
    /// 2. `/usr/local/bin/tron` — historical Homebrew Intel fallback.
    /// 3. `/opt/homebrew/bin/tron` — Homebrew Apple Silicon fallback.
    ///
    /// `home` is injectable so tests can point at a fixture without
    /// depending on the developer's machine layout.
    static func resolveBinary(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            home.appendingPathComponent(".local/bin/tron"),
            URL(fileURLWithPath: "/usr/local/bin/tron"),
            URL(fileURLWithPath: "/opt/homebrew/bin/tron"),
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}
