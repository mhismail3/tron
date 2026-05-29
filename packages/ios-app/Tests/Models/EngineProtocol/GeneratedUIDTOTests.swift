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
            "expiresAt": "2100-01-01T00:00:00Z",
            "presentation": {"tone": "neutral", "buttonRole": "neutral", "icon": "arrow.clockwise"}
          }],
          "redactionPolicy": {"mode": "redacted"},
          "expiresAt": "2100-01-01T00:00:00Z",
          "refreshPolicy": {"mode": "manual"},
          "authoring": {
            "mode": "generated",
            "targetType": "worker",
            "targetId": "control",
            "targetRevision": 7,
            "catalogRevision": 9,
            "projectionHash": "hash:abc",
            "maxPreviewBytes": 1024,
            "createdByInvocationId": "redacted:invocation"
          }
        }
        """
        let surface = try JSONDecoder().decode(UiSurfaceDTO.self, from: Data(surfaceJSON.utf8))

        #expect(surface.catalog.id == "tron.ui.catalog.core.v1")
        #expect(surface.layout.children?.first?.type == "Text")
        #expect(surface.actions.first?.targetFunctionId == "control::snapshot")
        #expect(surface.actions.first?.presentation?.icon == "arrow.clockwise")
        #expect(surface.authoring?.mode == "generated")
        #expect(surface.authoring?.targetType == "worker")

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
          "actions": [{"actionId": "refresh", "label": "Refresh", "targetFunctionId": "control::snapshot", "requiredRisk": "low", "presentation": {"tone": "neutral", "buttonRole": "neutral", "icon": "arrow.clockwise"}}]
        }
        """
        let ref = try JSONDecoder().decode(UiSurfaceRefDTO.self, from: Data(refJSON.utf8))

        #expect(ref.resourceId == "res-ui")
        #expect(ref.actions?.first?.targetFunctionId == "control::snapshot")
        #expect(ref.actions?.first?.presentation?.buttonRole == "neutral")
    }

    @Test("decodes ui surface inspection validation and mutation responses")
    func decodesSurfaceLifecycleResponses() throws {
        let inspectJSON = """
        {
          "inspection": {"resource": {"resourceId": "res-ui"}},
          "surface": {
            "surfaceId": "surface-1",
            "title": "Substrate",
            "purpose": "Inspect state",
            "catalog": {"id": "tron.ui.catalog.core.v1", "revision": 1},
            "layout": {"type": "Text", "props": {"text": "hello"}},
            "bindings": [],
            "actions": [],
            "redactionPolicy": {"mode": "redacted"},
            "expiresAt": "2100-01-01T00:00:00Z",
            "refreshPolicy": {"mode": "manual"}
          },
          "resourceRef": {"resourceId": "res-ui", "versionId": "ver-ui", "kind": "ui_surface"},
          "validationState": "valid",
          "bindings": [],
          "actions": [],
          "lineage": {"versionCount": 1}
        }
        """
        let inspected = try JSONDecoder().decode(UiSurfaceInspectResultDTO.self, from: Data(inspectJSON.utf8))
        #expect(inspected.surface?.surfaceId == "surface-1")
        #expect(inspected.resourceRef?.versionId == "ver-ui")

        let validationJSON = #"{"surfaceResourceId":"res-ui","validationState":"stale","diagnostics":[{"code":"stale_target_revision"}]}"#
        let validation = try JSONDecoder().decode(UiSurfaceValidationDTO.self, from: Data(validationJSON.utf8))
        #expect(validation.validationState == "stale")

        let mutationJSON = #"{"surface":{"surfaceId":"surface-1","title":"Substrate","purpose":"Inspect","catalog":{"id":"tron.ui.catalog.core.v1","revision":1},"layout":{"type":"Text","props":{"text":"hello"}},"bindings":[],"actions":[],"redactionPolicy":{"mode":"redacted"},"expiresAt":"2100-01-01T00:00:00Z","refreshPolicy":{"mode":"manual"}},"resourceRefs":[{"resourceId":"res-ui","versionId":"ver-ui","kind":"ui_surface"}]}"#
        let mutation = try JSONDecoder().decode(UiSurfaceMutationResultDTO.self, from: Data(mutationJSON.utf8))
        #expect(mutation.resourceRefs.first?.resourceId == "res-ui")
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
