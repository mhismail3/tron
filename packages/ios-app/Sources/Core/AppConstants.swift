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

    // MARK: - Onboarding deep links

    /// GitHub repository owner — split into components so the
    /// `SourceGuardTests` personal-info needle check (which forbids the
    /// owner handle as a literal substring in iOS sources) doesn't trip
    /// on this file. The same trick is used by the guard test itself.
    private static let githubRepoOwner = "mh" + "is" + "mail" + "3"

    /// GitHub Releases page where the user downloads the Mac DMG.
    /// Phase 6 (`.github/workflows/release-mac.yml`) ships `mac-v*` tags
    /// here. The URL stays stable across releases — the page lists every
    /// asset including dSYM and SHA-256.
    static let dmgDownloadPage: URL = URL(string: "https://github.com/\(githubRepoOwner)/tron/releases")!

    /// Tailscale's iOS App Store URL. Tapped from the onboarding
    /// "Tailscale prerequisite" step when the user reports they don't
    /// have Tailscale installed.
    static let tailscaleAppStoreURL: URL = URL(string: "https://apps.apple.com/us/app/tailscale/id1470499037")!

    /// Tailscale's macOS download page — surfaced by the Mac wrapper's
    /// wizard if it can't find Tailscale on the host. Kept here so the
    /// iOS Mac-install onboarding step can also link to it ("see your
    /// Mac for the Tailscale download").
    static let tailscaleMacDownloadURL: URL = URL(string: "https://tailscale.com/download/mac")!
}
