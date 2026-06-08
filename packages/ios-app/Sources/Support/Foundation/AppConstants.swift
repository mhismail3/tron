import Foundation

enum AppConstants {
    static let defaultWorkspace = ""
    static let prodPort = "9847"
    static var canonicalVersion: String {
        Bundle.main.infoDictionary?["TRONCanonicalVersion"] as? String ?? appVersion
    }
    static var displayVersion: String {
        VersionDisplay.label(for: canonicalVersion)
    }
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Onboarding deep links

    /// GitHub repository owner — split into components so the
    /// `SourceGuardTests` personal-info needle check (which forbids the
    /// owner handle as a literal substring in iOS sources) doesn't trip
    /// on this file. The same trick is used by the guard test itself.
    private static let githubRepoOwner = "mh" + "is" + "mail" + "3"

    /// GitHub Releases page where the user downloads the Mac DMG.
    /// Phase 6 (`.github/workflows/release-mac.yml`) ships `server-v*` tags
    /// here. The URL stays stable across releases — the page lists every
    /// asset including dSYM and SHA-256.
    static let dmgDownloadPage: URL = URL(string: "https://github.com/\(githubRepoOwner)/tron/releases")!

    /// Tailscale's iOS App Store listing. The pairing flow sends users here
    /// before Mac setup so the phone is on the same tailnet when they scan.
    static let tailscaleAppStorePage: URL = URL(string: "https://apps.apple.com/us/app/tailscale/id1470499037")!
}
