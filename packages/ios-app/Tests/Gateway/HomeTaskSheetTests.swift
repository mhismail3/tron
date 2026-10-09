import XCTest
@testable import TronMobile
import TronMobileCore

/// Task and permission DTO admission. Late read publication is owned by `HomeSheetTests`.
@MainActor
final class HomeTaskSheetTests: XCTestCase {
    private func page() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(#"{"items":[{"taskId":"task-one","createdAt":1000,"updatedAt":1001,"title":"Finite work","target":"/trusted/project","lifecycle":"terminal","outcome":"unknown","spend":{"sourceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","inputTokens":10,"outputTokens":4,"knownCostUSD":null,"pricingProvenance":null,"unpriced":true},"attention":true,"pendingGrant":false}]}"#.utf8))
    }

    func testTaskPageAdmitsUnknownOutcomeButRejectsUnknownLifecycleAndInvalidSpend() throws {
        let decoded = try HomeTaskPageDTO.decode(page())
        XCTAssertEqual(decoded.items[0].outcome, .unknown)
        XCTAssertNil(decoded.items[0].spend?.knownCostUSD)
        XCTAssertEqual(decoded.items[0].spend?.unpriced, true)
        for change in [("lifecycle", JSONValue.string("future-state")), ("outcome", .string("success")),
                       ("createdAt", .number(-1)), ("updatedAt", .number(0)), ("taskId", .string("../other")),
                       ("spend", .object(["inputTokens": .number(-1)]))] {
            var value = try page().objectValue!
            var row = value["items"]!.arrayValue![0].objectValue!
            row[change.0] = change.1; value["items"] = .array([.object(row)])
            XCTAssertThrowsError(try HomeTaskPageDTO.decode(.object(value)), change.0)
        }
    }

    func testPermissionsRejectUnknownGrantAndDuplicateDecisionsWithoutLosingRequestBinding() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"revision":1,"scopes":[],"requests":[{"id":"request-one","request":{"intentRevision":1,"intentDigest":"digest","target":"/trusted/project","authorizationScope":"full-work","workerProfile":"home-task-v1","policyRevision":1,"restoreEpoch":"epoch"}}],"decisions":[],"grants":[]}"#.utf8))
        let decoded = try HomeTaskPermissionsDTO.decode(value)
        XCTAssertEqual(decoded.pendingRequests[0].request.target, "/trusted/project")
        var wrong = value.objectValue!
        var grant = value.objectValue!["requests"]!.arrayValue![0].objectValue!["request"]!.objectValue!
        grant["id"] = .string("grant"); grant["decisionId"] = .string("approved-decision")
        grant["expiresAt"] = .number(2000); grant["state"] = .string("future")
        wrong["decisions"] = .array([.object(["id": .string("approved-decision"), "requestId": .string("request-one"),
            "approved": .bool(true), "decidedAt": .number(1000), "expiresAt": .number(2000)])])
        wrong["grants"] = .array([.object(grant)])
        XCTAssertThrowsError(try HomeTaskPermissionsDTO.decode(.object(wrong)))
        let decision: JSONValue = .object(["id": .string("decision"), "requestId": .string("request-one"),
            "approved": .bool(false), "decidedAt": .number(1000), "expiresAt": .number(2000)])
        wrong = value.objectValue!; wrong["decisions"] = .array([decision, decision])
        XCTAssertThrowsError(try HomeTaskPermissionsDTO.decode(.object(wrong)))
    }
}
