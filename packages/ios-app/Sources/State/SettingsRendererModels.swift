import Foundation
import TronMobileCore

/// The renderer contract this app speaks (gateway docs/settings-model.md 7.5).
/// It names only the controls implemented here: the Gateway serves any other
/// control's declared fallback, or read-only, so a key never disappears.
enum SettingsRendererContract {
    static let version = 1
    static let controls = ["toggle", "choice", "number", "text", "secret", "list", "checklist", "catalog", "readOnly"]
}

/// The control one row renders with. A control this app does not implement, or
/// a missing presentation, is read-only: the row still shows its `display`.
enum SettingsRowControl: String, Equatable, Sendable {
    case toggle, choice, number, text, secret, list, checklist, catalog, readOnly

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
    /// What to type into the key's text field or a list's new value (#939).
    let entry: SettingsEntryGuidance?
    /// UI-editable scopes, timing and effect are declared by the Gateway, not iOS.
    let editableLayers: [String]?
    let timing: JSONValue?
    let effect: String?
}

/// A view of canonical resolution, not a second store or a list of key definitions.
enum SettingsKeySelection: Equatable {
    case all
    case editable([String])
    case overrides(String)
    case launchInputs

    func includes(_ setting: ResolvedSetting) -> Bool {
        switch self {
        case .all: true
        case .editable(let layers):
            layers.contains { layer in
                setting.layers.contains { $0.layer == layer }
                    && (setting.presentation?.editableLayers?.contains(layer) ?? true)
            }
        case .overrides(let layer):
            setting.layers.contains { $0.layer == layer && ($0.value != nil || $0.display != nil) }
                && (layer != "chat" || setting.origin == "override")
        case .launchInputs:
            setting.layer == "chat" && setting.origin != "override"
        }
    }
}

/// The schema's entry guidance: the format in one sentence and a realistic
/// example, shown as the field's placeholder. iOS never writes its own.
struct SettingsEntryGuidance: Decodable, Equatable, Sendable {
    let hint: String
    let example: String
}

struct SettingsChoice: Decodable, Equatable, Sendable {
    let value: JSONValue
    let label: String
    /// One line on what choosing it changes.
    let detail: String?
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
    let resource: JSONValue?

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

/// A section the Gateway orders. Its id and title are Gateway text: a section
/// iOS has never heard of renders with the same generic code.
struct SettingsRendererSection: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    /// The one line shown beside the title; a group no section declares has none.
    let description: String?
    let order: Int
    let note: String?
    let chatInline: Bool

    private enum CodingKeys: String, CodingKey { case id, title, description, order, note, chatInline }

    /// A group a key names that no served section declares: shown under its id,
    /// last, so its values are never hidden.
    init(id: String) {
        self.id = id
        title = id
        description = nil
        order = .max
        note = nil
        chatInline = false
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        note = try container.decodeIfPresent(String.self, forKey: .note)
        chatInline = try container.decodeIfPresent(Bool.self, forKey: .chatInline) ?? false
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
            let details: JSONValue?
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
        guard let failure = changes.compactMap(\.error).first else { return }
        throw GatewayFailure(code: failure.code, message: failure.message, retryable: false, details: failure.details)
    }
}
