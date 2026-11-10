import Foundation
import TronMobileCore

enum SettingsRendererPresentation: Hashable {
    case section(String)
    case instances(key: String)
    case keys([String])
}

func settingsRowIdentifier(_ setting: ResolvedSetting) -> String {
    "settings-row-" + String(setting.id.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
    })
}
