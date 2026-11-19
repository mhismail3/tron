import Foundation
import TronMobileCore

struct SettingsBadge: Decodable, Hashable, Sendable {
    struct Action: Decodable, Hashable, Sendable {
        let kind: String
        let label: String
        var changeId: String? = nil
    }
    let kind: String
    let label: String
    let detail: String?
    let action: Action?

    init(kind: String, label: String, detail: String?, action: Action? = nil) {
        self.kind = kind; self.label = label; self.detail = detail; self.action = action
    }
}

struct ResolvedSetting: Decodable, Equatable, Sendable, Identifiable {
    let key: String
    let qualifiers: [String: String]?
    let group: String
    let subgroup: String?
    let value: JSONValue?
    let display: String
    let layer: String
    let applied: Bool
    let badges: [SettingsBadge]
    struct Layer: Decodable, Equatable, Sendable {
        let layer: String
        let value: JSONValue?
        let display: String?
        var applied: Bool? = nil
        var reason: String? = nil
    }
    let layers: [Layer]
    var overridden: Bool? = nil

    var id: String { settingIdentity(key: key, qualifiers: qualifiers) }

    func badge(_ kind: String) -> SettingsBadge? { badges.first { $0.kind == kind } }

    func value(at layer: String) -> JSONValue? { layers.first { $0.layer == layer }?.value }
}

struct SettingsResolution: Decodable, Sendable {
    let keys: [ResolvedSetting]

    func setting(_ key: String) -> ResolvedSetting? { keys.first { $0.key == key } }
}
