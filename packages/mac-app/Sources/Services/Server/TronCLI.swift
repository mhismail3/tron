import Foundation

/// Resolves the runtime `tron` CLI script across the canonical install
/// locations.
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
    /// 1. Bundled `tron-cli` resource — always present in the Mac wrapper.
    /// 2. `~/.local/bin/tron` — canonical symlink planted by CLI installs.
    /// 3. `~/.tron/system/deployment/tron-cli` — canonical runtime script.
    ///
    /// `home` is injectable so tests can point at a fixture without
    /// depending on the developer's machine layout.
    static func resolveBinary(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledRuntimeCLI: URL? = Bundle.main.url(forResource: "tron-cli", withExtension: nil),
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            bundledRuntimeCLI,
            home.appendingPathComponent(".local/bin/tron"),
            home.appendingPathComponent(".tron/system/deployment/tron-cli"),
        ].compactMap(\.self)
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}
