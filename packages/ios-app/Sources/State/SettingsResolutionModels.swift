import Foundation
import TronMobileCore

struct SettingsBadge: Decodable, Hashable, Sendable {
    let kind: String
    let label: String
    let detail: String?
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
    var projectSetting: SettingsProjectSource? = nil
    let presentation: SettingsKeyPresentation

    var id: String { settingIdentity(key: key, qualifiers: qualifiers) }

    func badge(_ kind: String) -> SettingsBadge? { badges.first { $0.kind == kind } }

    func value(at layer: String) -> JSONValue? { layers.first { $0.layer == layer }?.value }
}

struct SettingsProjectSource: Decodable, Equatable, Sendable {
    let file: String
    let path: String
}

struct SettingsProjectNotice: Decodable, Sendable {
    let file: String
    let message: String
}

struct SettingsProjectDiagnostic: Decodable, Sendable {
    let file: String
    let key: String
    let path: String
    let reason: String
}

struct SettingsResolution: Decodable, Sendable {
    let keys: [ResolvedSetting]
    let sections: [SettingsRendererSection]

    let projectNotice: SettingsProjectNotice?
    let diagnostics: [SettingsProjectDiagnostic]
    let diagnosticsTruncated: Bool
    private enum CodingKeys: String, CodingKey { case keys, sections, projectNotice, diagnostics, diagnosticsTruncated }

    func setting(_ key: String) -> ResolvedSetting? { keys.first { $0.key == key } }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectNotice = try container.decodeIfPresent(SettingsProjectNotice.self, forKey: .projectNotice)
        diagnostics = try container.decodeIfPresent([SettingsProjectDiagnostic].self, forKey: .diagnostics) ?? []
        diagnosticsTruncated = try container.decodeIfPresent(Bool.self, forKey: .diagnosticsTruncated) ?? false
        keys = try container.decode([ResolvedSetting].self, forKey: .keys)
        sections = try container.decodeIfPresent([SettingsRendererSection].self, forKey: .sections) ?? []
    }
}
