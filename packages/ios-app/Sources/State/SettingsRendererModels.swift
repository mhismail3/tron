import Foundation
import TronMobileCore

/// The renderer contract this app speaks (gateway docs/settings-model.md 7.5).
/// It names only the controls implemented here: the Gateway serves any other
/// control's declared fallback, or read-only, so a key never disappears.
enum SettingsRendererContract {
    static let version = 1
    static let controls = ["toggle", "choice", "number", "text", "secret", "list", "catalog", "readOnly"]
}

/// The control one row renders with. A control this app does not implement, or
/// a missing presentation, is read-only: the row still shows its `display`.
enum SettingsRowControl: String, Equatable, Sendable {
    case toggle, choice, number, text, secret, list, catalog, readOnly

    init(negotiated control: String?) {
        self = control.flatMap(Self.init(rawValue:)) ?? .readOnly
    }
}

/// The identity of one resolved key instance: its key id and qualifiers.
func settingIdentity(key: String, qualifiers: [String: String]?) -> String {
    ([key] + (qualifiers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: "|")
}

/// How a key is presented (gateway docs/settings-model.md 7.5a). The Gateway
/// reads it from the schema; iOS decides only the layout that fits it.
struct SettingsKeyPresentation: Decodable, Equatable, Sendable {
    let label: String
    let help: String
    let order: Int
    let importance: String
    /// The negotiated control, already a control the client named or a fallback.
    let control: String
    let note: String?
    let valueKind: String?
    /// Static choices, or field names/labels for a `numberMap` list.
    let options: [SettingsChoice]?
    let range: SettingsRange?
    let optionsSource: SettingsOptionsSource?
    let confirm: String?
    let redacted: Bool?
}

struct SettingsChoice: Decodable, Equatable, Sendable {
    let value: JSONValue
    let label: String
}

struct SettingsRange: Decodable, Equatable, Sendable {
    let min: Double
    let max: Double
    let step: Double?
    let unit: String?

    /// Representation safety, not key validation: unsupported numeric metadata
    /// stays visible read-only instead of trapping during Double → Int conversion.
    var supportsIntegerSlider: Bool {
        let exactLimit = 9_007_199_254_740_991.0
        guard min >= 0, max >= min, max <= exactLimit,
              Int(exactly: min) != nil, Int(exactly: max) != nil else { return false }
        guard let step else { return true }
        return step > 0 && step <= exactLimit && Int(exactly: step) != nil
    }
}

struct SettingsOptionsSource: Decodable, Equatable, Sendable {
    let name: String
    let dependsOn: [String]
}

/// One choice `settings.options` serves for a key (gateway docs/settings-model.md 7.5).
struct SettingsOption: Decodable, Equatable, Sendable, Identifiable {
    let value: JSONValue
    let label: String
    let detail: String?
    let disabledReason: String?

    var id: JSONValue { value }
}

struct SettingsOptionsResponse: Decodable, Equatable, Sendable {
    let key: String
    let source: String
    let dependsOn: [String]
    let options: [SettingsOption]
    let range: SettingsRange?
    let nextCursor: String?
}

/// One section's summary (gateway docs/settings-model.md 7.2). An absent list
/// is empty, so a newer Gateway's extra fields never hide a section.
struct SettingsSectionSummary: Decodable, Equatable, Sendable {
    let essential: [SettingsSummaryValue]
    let overrides: [SettingsSummaryOverride]
    let pending: [SettingsPendingSummary]
    let recent: [SettingsRecentChange]
    let moreRecent: Int

    private enum CodingKeys: String, CodingKey { case essential, overrides, pending, recent, moreRecent }

    init(essential: [SettingsSummaryValue] = [], overrides: [SettingsSummaryOverride] = [],
         pending: [SettingsPendingSummary] = [], recent: [SettingsRecentChange] = [], moreRecent: Int = 0) {
        self.essential = essential
        self.overrides = overrides
        self.pending = pending
        self.recent = recent
        self.moreRecent = moreRecent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        essential = try container.decodeIfPresent([SettingsSummaryValue].self, forKey: .essential) ?? []
        overrides = try container.decodeIfPresent([SettingsSummaryOverride].self, forKey: .overrides) ?? []
        pending = try container.decodeIfPresent([SettingsPendingSummary].self, forKey: .pending) ?? []
        recent = try container.decodeIfPresent([SettingsRecentChange].self, forKey: .recent) ?? []
        moreRecent = try container.decodeIfPresent(Int.self, forKey: .moreRecent) ?? 0
    }
}

struct SettingsSummaryValue: Decodable, Equatable, Sendable {
    let key: String
    let qualifiers: [String: String]?
    let label: String
    let display: String
}

struct SettingsSummaryOverride: Decodable, Equatable, Sendable {
    let key: String
    let qualifiers: [String: String]?
    let label: String
    let display: String
    let layer: String
    let layerLabel: String
}

struct SettingsPendingSummary: Decodable, Equatable, Sendable {
    let requestId: String
    let requester: String
    let labels: [String]
}

struct SettingsRecentChange: Decodable, Equatable, Sendable {
    let changeId: String
    let key: String
    let label: String
    let actor: String
    let reason: String?
    let at: String
}

/// A section the Gateway orders. Its id and title are Gateway text: a section
/// iOS has never heard of renders with the same generic code.
struct SettingsRendererSection: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let order: Int
    let note: String?
    let summary: SettingsSectionSummary

    private enum CodingKeys: String, CodingKey { case id, title, order, note, summary }

    /// A group a key names that no served section declares: shown under its id,
    /// last, so its values are never hidden.
    init(id: String) {
        self.id = id
        title = id
        order = .max
        note = nil
        summary = SettingsSectionSummary()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        note = try container.decodeIfPresent(String.self, forKey: .note)
        summary = try container.decodeIfPresent(SettingsSectionSummary.self, forKey: .summary) ?? SettingsSectionSummary()
    }
}

/// A dry run's or an applied change's outcome (gateway docs/settings-model.md 5.2).
/// A failed change's `error.message` is shown inline; nothing is applied. Only
/// the fields the renderer reads are named, so an outcome missing the rest still decodes.
struct SettingsChangeResult: Decodable, Equatable, Sendable {
    struct Outcome: Decodable, Equatable, Sendable {
        struct Failure: Decodable, Equatable, Sendable {
            let code: String
            let message: String
        }

        let tier: String?
        let error: Failure?
        /// The key's `confirm` text when the change needs the maintainer's tap first.
        let confirm: String?
    }

    /// The request's tier: the highest of its changes. An applied change's result may omit it.
    let tier: String?
    let changes: [Outcome]

    private enum CodingKeys: String, CodingKey { case tier, changes }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = try container.decodeIfPresent(String.self, forKey: .tier)
        changes = try container.decodeIfPresent([Outcome].self, forKey: .changes) ?? []
    }

    /// The refusal the first change carries, if any, as the Gateway's own failure.
    func throwIfRefused() throws {
        guard let failure = changes.first?.error else { return }
        throw GatewayFailure(code: failure.code, message: failure.message, retryable: false, details: nil)
    }
}
