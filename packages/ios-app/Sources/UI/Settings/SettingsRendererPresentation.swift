import Foundation
import TronMobileCore

/// What a renderer shows. Surfaces choose; the Gateway still supplies every word.
enum SettingsRendererPresentation: Hashable {
    /// One section's sheet: every key, grouped, with sources, help and actions.
    case section(String)
    /// Every instance of one key on its own sheet (per project, per governed setting).
    case instances(key: String)
    /// Just these keys, as inline rows inside a caller's card.
    case keys([String])
}

/// Converts a resolved row into the Gateway's identifier alphabet for UI tests.
func settingsRowIdentifier(_ setting: ResolvedSetting) -> String {
    "settings-row-" + String(setting.id.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
    })
}
