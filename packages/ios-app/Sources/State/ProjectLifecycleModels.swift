import Foundation
import TronMobileCore

struct ProjectLifecycleEligibility: Decodable, Sendable {
    let allowed: Bool
    let code: String?
    let reason: String?
    var refusal: String? { reason }

    private enum CodingKeys: String, CodingKey { case allowed, code, reason }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try values.decode(Bool.self, forKey: .allowed)
        code = allowed ? nil : try values.decode(String.self, forKey: .code)
        reason = allowed ? nil : try values.decode(String.self, forKey: .reason)
    }
}

struct ProjectLifecycleRow: Decodable, Identifiable, Sendable {
    struct Eligibility: Decodable, Sendable {
        let trust, untrust: ProjectLifecycleEligibility
    }
    struct Trust: Decodable, Sendable {
        let effectiveDecision: Bool?
    }
    let name: String
    let path: String
    let trust: Trust?
    let eligibility: Eligibility
    var id: String { path }
}

struct ProjectLifecycleListing: Decodable, Sendable {
    let workspace: String
    var projects: [ProjectLifecycleRow]
    let nextCursor: String?
}

enum ProjectLifecycleOperation: String, Sendable {
    case create, trust, untrust
}

struct ProjectLifecycleReviewResult: Decodable {
    let status: String
    let review: ChangeReview
    let intent: JSONValue
}

struct ProjectLifecycleReview: Identifiable {
    let params: [String: JSONValue]
    let review: ChangeReview
    let intent: JSONValue
    var id: String { review.digest }
}
