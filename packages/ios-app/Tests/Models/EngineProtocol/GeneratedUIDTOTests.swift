import Foundation
import Testing
@testable import TronMobile

@Suite("Generated UI DTOs")
struct GeneratedUIDTOTests {
    @Test("decodes ui_surface payload and control refs")
    func decodesSurfaceAndRefs() throws {
        let surfaceJSON = """
        {
          "surfaceId": "surface-1",
          "title": "Substrate",
          "purpose": "Inspect state",
          "catalog": {"id": "tron.ui.catalog.core.v1", "revision": 1},
          "layout": {"type": "Section", "props": {"title": "Root"}, "children": [{"type": "Text", "props": {"text": "hello"}}]},
          "bindings": [{"targetType": "worker", "targetId": "control"}],
          "actions": [{
            "actionId": "refresh",
            "label": "Refresh",
            "targetFunctionId": "control::snapshot",
            "inputSchema": {"type": "object", "additionalProperties": false},
            "payloadTemplate": {},
            "idempotencyKeyTemplate": "${submission.idempotencyKey}",
            "requiredGrant": "grant",
            "requiredRisk": "low",
            "approvalPolicy": {"required": false},
            "targetRevision": 1,
            "expiresAt": "2100-01-01T00:00:00Z"
          }],
          "redactionPolicy": {"mode": "redacted"},
          "expiresAt": "2100-01-01T00:00:00Z",
          "refreshPolicy": {"mode": "manual"}
        }
        """
        let surface = try JSONDecoder().decode(UiSurfaceDTO.self, from: Data(surfaceJSON.utf8))

        #expect(surface.catalog.id == "tron.ui.catalog.core.v1")
        #expect(surface.layout.children?.first?.type == "Text")
        #expect(surface.actions.first?.targetFunctionId == "control::snapshot")

        let refJSON = """
        {
          "resourceId": "res-ui",
          "versionId": "ver-ui",
          "kind": "ui_surface",
          "lifecycle": "active",
          "surfaceId": "surface-1",
          "title": "Substrate",
          "purpose": "Inspect state",
          "catalog": {"id": "tron.ui.catalog.core.v1", "revision": 1},
          "expiresAt": "2100-01-01T00:00:00Z",
          "targets": [{"targetType": "worker", "targetId": "control"}],
          "actions": [{"actionId": "refresh", "label": "Refresh", "targetFunctionId": "control::snapshot", "requiredRisk": "low"}]
        }
        """
        let ref = try JSONDecoder().decode(UiSurfaceRefDTO.self, from: Data(refJSON.utf8))

        #expect(ref.resourceId == "res-ui")
        #expect(ref.actions?.first?.targetFunctionId == "control::snapshot")
    }

    @Test("action submission encodes only stored action coordinates")
    func actionSubmissionEncodesOnlyCoordinates() throws {
        let submission = UiActionSubmissionDTO(
            surfaceResourceId: "res-ui",
            surfaceVersionId: "ver-ui",
            actionId: "promote",
            userInput: ["reason": AnyCodable("operator")],
            idempotencyKey: "ui-action-1"
        )
        let data = try JSONEncoder().encode(submission)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["surfaceResourceId", "surfaceVersionId", "actionId", "userInput", "idempotencyKey"])
        #expect(object["targetFunctionId"] == nil)
        #expect(object["payloadTemplate"] == nil)
    }
}
