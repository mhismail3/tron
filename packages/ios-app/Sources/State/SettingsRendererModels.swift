import Foundation
import TronMobileCore

enum SettingsRendererContract {
    static let version = 1
    static let controls = ["toggle", "choice", "text", "secret", "list", "checklist", "catalog", "readOnly"]
}

enum SettingsRowControl: String, Equatable, Sendable {
    case toggle, choice, text, secret, list, checklist, catalog, readOnly

    init(negotiated control: String?) {
        self = control.flatMap(Self.init(rawValue:)) ?? .readOnly
    }
}

func settingIdentity(key: String, qualifiers: [String: String]?) -> String {
    ([key] + (qualifiers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: "|")
}

struct SettingsKeyPresentation: Decodable, Equatable, Sendable {
    let label: String
    let help: String
    let order: Int
    let importance: String
    let control: String?
    let note: String?
    let valueKind: String?
    let options: [SettingsChoice]?
    let optionsSource: SettingsOptionsSource?
    let redacted: Bool?
    let entry: SettingsEntryGuidance?
    let sessionOverridable: Bool
    let editable: Bool
}

enum SettingsKeySelection: Equatable {
    case all
    case allExcept(Set<String>)
    case editable(excluding: Set<String>)
    case sessionOverrides
    case sessionOverridesExcept(Set<String>)
    case projectValues

    func includes(_ setting: ResolvedSetting) -> Bool {
        guard setting.key != "context.compaction.enabled",
              setting.key != "model.thinking[role=summarizer]" else { return false }
        switch self {
        case .all: return true
        case .allExcept(let excluded): return !excluded.contains(setting.key)
        case .editable(let excluded):
            return !excluded.contains(setting.key) && setting.presentation.editable
        case .sessionOverrides:
            return setting.presentation.sessionOverridable && setting.presentation.editable
        case .sessionOverridesExcept(let excluded):
            return Self.sessionOverrides.includes(setting) && !excluded.contains(setting.key)
        case .projectValues: return setting.projectSetting != nil
        }
    }
}

struct SettingsEntryGuidance: Decodable, Equatable, Sendable {
    let hint: String
    let example: String
}

struct SettingsChoice: Decodable, Equatable, Sendable {
    let value: JSONValue
    let label: String
    let detail: String?
}

struct SettingsOptionsSource: Decodable, Equatable, Sendable {
    let name: String
}

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
    let options: [SettingsOption]
    let nextCursor: String?
}

struct SettingsRendererSection: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let order: Int
    let note: String?

    private enum CodingKeys: String, CodingKey { case id, title, description, order, note }

    init(id: String) {
        self.id = id
        title = id
        description = nil
        order = .max
        note = nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

struct SettingsChangeResult: Decodable, Equatable, Sendable {
    struct Outcome: Decodable, Equatable, Sendable {
        struct Failure: Decodable, Equatable, Sendable {
            let code: String
            let message: String
            let details: JSONValue?
        }

        let error: Failure?
    }

    let status: String?
    let review: ChangeReview?
    let changes: [Outcome]

    private enum CodingKeys: String, CodingKey { case status, review, changes }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        review = try container.decodeIfPresent(ChangeReview.self, forKey: .review)
        changes = try container.decodeIfPresent([Outcome].self, forKey: .changes) ?? []
    }

    func throwIfRefused() throws {
        if status == "review" { throw GatewayFailure(code: "conflict", message: "An exact native review is required; nothing changed.", retryable: false, details: nil) }
        guard let failure = changes.compactMap(\.error).first else { return }
        throw GatewayFailure(code: failure.code, message: failure.message, retryable: false, details: failure.details)
    }
}
