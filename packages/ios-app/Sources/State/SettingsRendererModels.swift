import Foundation
import TronMobileCore

func settingIdentity(key: String, qualifiers: [String: String]?) -> String {
    ([key] + (qualifiers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: "|")
}

struct SettingsOption: Decodable, Equatable, Sendable, Identifiable {
    let value: JSONValue
    let label: String
    let detail: String?
    let disabledReason: String?
    let resource: JSONValue?

    var id: JSONValue { value }
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
