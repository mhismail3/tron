import Foundation

enum AppConstants {
    static let macDownloadURLInfoPlistKey = "TRONMacDownloadURL"
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

    /// GitHub Releases page where the user downloads the Mac DMG.
    /// Local builds use the tracked generic placeholder from `Base.xcconfig`;
    /// release or maintainer builds may override it through `Local.xcconfig`
    /// or CI build settings.
    static var dmgDownloadPage: URL {
        configuredURL(infoDictionary: Bundle.main.infoDictionary, key: macDownloadURLInfoPlistKey)
            ?? URL(string: "https://github.com/tron-owner/tron/releases")!
    }

    /// Tailscale's iOS App Store listing. The pairing flow sends users here
    /// before Mac setup so the phone is on the same tailnet when they scan.
    static let tailscaleAppStorePage: URL = URL(string: "https://apps.apple.com/us/app/tailscale/id1470499037")!

    static func configuredURL(infoDictionary: [String: Any]?, key: String) -> URL? {
        guard let raw = infoDictionary?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return URL(string: trimmed)
    }
}
