import Foundation

/// Removes only the installer-owned launch artifacts so a failed or
/// interrupted install can be retried from a clean state without
/// deleting user data. Auth, settings, and the SQLite database live
/// elsewhere under `~/.tron/system/` and are intentionally preserved.
enum InstallArtifactCleaner {
    static func clean(
        installedBundle: URL,
        launchAgentPlistPath: URL,
        launchAgentManager: LaunchAgentManaging,
        label: String,
        emptyDirectoriesToRemove: [URL] = []
    ) async -> InstallCleanupOutcome {
        if await launchAgentManager.isLoaded(label: label) {
            let outcome = await launchAgentManager.unload(label: label)
            guard outcome.isCleanupSuccess else {
                return .failed("Could not unload LaunchAgent: \(outcome.userMessage)")
            }
        }

        var removed: [String] = []
        let fm = FileManager.default
        for url in [installedBundle, launchAgentPlistPath] where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                removed.append(url.path)
            } catch {
                return .failed("Could not remove \(url.path): \(error.localizedDescription)")
            }
        }

        for directory in emptyDirectoriesToRemove where fm.fileExists(atPath: directory.path) {
            do {
                let contents = try fm.contentsOfDirectory(atPath: directory.path)
                guard contents.isEmpty else { continue }
                try fm.removeItem(at: directory)
                removed.append(directory.path)
            } catch {
                return .failed("Could not remove empty directory \(directory.path): \(error.localizedDescription)")
            }
        }

        return .success(removed: removed)
    }
}

enum InstallCleanupOutcome: Equatable, Sendable {
    case success(removed: [String])
    case failed(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var userMessage: String {
        switch self {
        case .success(let removed) where removed.isEmpty:
            return "No install artifacts needed cleanup."
        case .success:
            return "Removed stale install artifacts. Auth, settings, and database files were preserved."
        case .failed(let message):
            return message
        }
    }
}

private extension LaunchAgentOutcome {
    var isCleanupSuccess: Bool {
        switch self {
        case .ok, .alreadyLoaded:
            return true
        case .unknown(let message):
            return message.localizedCaseInsensitiveContains("Could not find service")
                || message.localizedCaseInsensitiveContains("No such process")
        case .launchdRefused, .binaryMissing:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .ok:
            return "OK"
        case .alreadyLoaded:
            return "Already loaded"
        case .launchdRefused(let message), .unknown(let message):
            return message
        case .binaryMissing(let path):
            return "Binary missing: \(path)"
        }
    }
}
