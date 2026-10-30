import Foundation
import TronMobileCore

/// One badge as the resolver returns it; iOS maps `kind` to a style only.
struct SettingsBadge: Decodable, Hashable, Sendable {
    struct Action: Decodable, Hashable, Sendable {
        let kind: String
        let label: String
        /// The record entry an action applies to (Apply again names its outside change).
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

/// One resolved key instance from `settings.resolve` (docs/settings-model.md 3.1).
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
        /// This layer's own stored value; absent when the layer holds none.
        let value: JSONValue?
        /// Redacted settings still expose whether this layer holds a value.
        let display: String?
        var applied: Bool? = nil
        var reason: String? = nil
    }
    let layers: [Layer]
    var overridden: Bool? = nil
    var projectSetting: SettingsProjectSource? = nil
    /// Absent from a Gateway that predates the renderer contract: the row is then read-only.
    let presentation: SettingsKeyPresentation?

    var id: String { settingIdentity(key: key, qualifiers: qualifiers) }

    func badge(_ kind: String) -> SettingsBadge? { badges.first { $0.kind == kind } }

    /// The served value, or one layer's own value for a surface that edits that
    /// layer and must not show what a higher layer overrides.
    func value(at layer: String) -> JSONValue? { layers.first { $0.layer == layer }?.value }
}

/// `settings.resolve`: the key instances and, when the request negotiated the
/// renderer contract, the sections that summarize them in the Gateway's order.
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

    /// The row for an unqualified schema key, when the Gateway served it for this target.
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
