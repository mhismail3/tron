import XCTest
@testable import TronMobile
import TronMobileCore

/// Task and permission DTO admission. Late read publication is owned by `HomeSheetTests`.
@MainActor
final class HomeTaskSheetTests: XCTestCase {
    private func page() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(#"{"items":[{"taskId":"task-one","createdAt":1000,"updatedAt":1001,"title":"Finite work","target":"/trusted/project","lifecycle":"terminal","outcome":"unknown","spend":{"sourceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","inputTokens":10,"outputTokens":4},"attention":true,"pendingGrant":false}]}"#.utf8))
    }

    func testTaskPageAdmitsUnknownOutcomeButRejectsUnknownLifecycleAndInvalidSpend() throws {
        let decoded = try HomeTaskPageDTO.decode(page())
        XCTAssertEqual(decoded.items[0].outcome, .unknown)
        XCTAssertEqual(decoded.items[0].spend?.inputTokens, 10)
        XCTAssertEqual(decoded.items[0].spend?.outputTokens, 4)
        for change in [("lifecycle", JSONValue.string("future-state")), ("outcome", .string("success")),
                       ("createdAt", .number(-1)), ("updatedAt", .number(0)), ("taskId", .string("../other")),
                       ("spend", .object(["inputTokens": .number(-1), "outputTokens": .number(0),
                                          "sourceDigest": .string(String(repeating: "a", count: 64))]))] {
            var value = try page().objectValue!
            var row = value["items"]!.arrayValue![0].objectValue!
            row[change.0] = change.1; value["items"] = .array([.object(row)])
            XCTAssertThrowsError(try HomeTaskPageDTO.decode(.object(value)), change.0)
        }
    }

    /// The Gateway no longer sends `intent.revision` or `controllerGeneration`. An active task is
    /// controllable by its operation ID alone, so its detail must decode without those counters.
    func testActiveTaskDecodesWithOperationIDAndWithoutRemovedCounters() throws {
        let active = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"taskId":"task-one","homeId":"home-one","createdAt":1000,"updatedAt":1001,"intent":{"text":"Finite work"},"target":"/trusted/project","lifecycle":"active","operationId":"operation-one","spend":null,"terminalEvidence":null,"wake":null}"#.utf8))
        let decoded = try HomeTaskDTO.decode(active, taskID: "task-one")
        XCTAssertEqual(decoded.operationId, "operation-one")
        XCTAssertEqual(decoded.intent.text, "Finite work")

        var missingOperation = active.objectValue!
        missingOperation["operationId"] = .null
        XCTAssertThrowsError(try HomeTaskDTO.decode(.object(missingOperation), taskID: "task-one"))
    }

    /// A grant matches its request on every remaining binding dimension. Removing
    /// `workerProfile` and `policyRevision` must not loosen target, digest, scope or epoch.
    func testGrantMustMatchItsRequestOnEachRemainingBindingDimension() throws {
        let decoded = try HomeTaskPermissionsDTO.decode(permissionDocument())
        XCTAssertEqual(decoded.grants.first?.binding.target, "/trusted/project")
        XCTAssertEqual(decoded.grants.first?.binding.restoreEpoch, "epoch")

        for change in [("intentRevision", JSONValue.number(2)), ("intentDigest", .string("other-digest")),
                       ("target", .string("/other/project")), ("authorizationScope", .string("other-scope")),
                       ("restoreEpoch", .string("other-epoch")), ("expiresAt", .number(3000))] {
            XCTAssertThrowsError(try HomeTaskPermissionsDTO.decode(permissionDocument(grantOverride: change)), change.0)
        }
    }

    func testPermissionsRejectUnknownGrantAndDuplicateDecisions() throws {
        var wrong = try permissionDocument(grantOverride: ("state", .string("future"))).objectValue!
        XCTAssertThrowsError(try HomeTaskPermissionsDTO.decode(.object(wrong)))

        let decision: JSONValue = .object(["id": .string("decision"), "requestId": .string("request-one"),
            "approved": .bool(false), "decidedAt": .number(1000), "expiresAt": .number(2000)])
        wrong = try permissionDocument().objectValue!; wrong["decisions"] = .array([decision, decision])
        XCTAssertThrowsError(try HomeTaskPermissionsDTO.decode(.object(wrong)))
    }

    /// One request, one approved decision and its grant. The request binding carries exactly the
    /// dimensions the Gateway still sends; `grantOverride` alters the grant's copy of one of them.
    private func permissionDocument(grantOverride: (String, JSONValue)? = nil) throws -> JSONValue {
        var grant = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"grant-one","decisionId":"decision-one","intentRevision":1,"intentDigest":"digest","target":"/trusted/project","authorizationScope":"full-work","restoreEpoch":"epoch","expiresAt":2000,"state":"available"}"#.utf8)).objectValue!
        if let grantOverride { grant[grantOverride.0] = grantOverride.1 }
        var document = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"revision":1,"scopes":[],"requests":[{"id":"request-one","request":{"intentRevision":1,"intentDigest":"digest","target":"/trusted/project","authorizationScope":"full-work","restoreEpoch":"epoch"}}],"decisions":[{"id":"decision-one","requestId":"request-one","approved":true,"decidedAt":1000,"expiresAt":2000}],"grants":[]}"#.utf8)).objectValue!
        document["grants"] = .array([.object(grant)])
        return .object(document)
    }
}
