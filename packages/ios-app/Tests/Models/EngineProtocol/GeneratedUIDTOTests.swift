import Foundation
import Testing
@testable import TronMobile

@Suite("Generated UI DTOs")
struct GeneratedUIDTOTests {
    @Test("decodes ui_surface payload and resource refs")
    func decodesSurfaceAndRefs() throws {
        let surfaceJSON = """
        {
          "surfaceId": "surface-1",
          "title": "Substrate",
          "purpose": "Inspect state",
          "schemaVersion": 1,
          "layout": {"type": "Section", "props": {"title": "Root"}, "children": [{"type": "Text", "props": {"text": "hello"}}]},
          "actions": [{
            "actionId": "refresh",
            "label": "Refresh",
            "inputSchema": {"type": "object", "additionalProperties": false},
            "expiresAt": "2100-01-01T00:00:00Z",
            "presentation": {"tone": "neutral", "buttonRole": "neutral", "icon": "arrow.clockwise"}
          }],
          "expiresAt": "2100-01-01T00:00:00Z"
        }
        """
        let surface = try JSONDecoder().decode(UiSurfaceDTO.self, from: Data(surfaceJSON.utf8))

        #expect(surface.schemaVersion == 1)
        #expect(surface.layout.children?.first?.type == "Text")
        #expect(surface.actions.first?.actionId == "refresh")
        #expect(surface.actions.first?.presentation?.icon == "arrow.clockwise")

        let refJSON = """
        {
          "resourceId": "res-ui",
          "versionId": "ver-ui",
          "kind": "ui_surface",
          "lifecycle": "active",
          "surfaceId": "surface-1",
          "title": "Substrate",
          "purpose": "Inspect state",
          "schemaVersion": 1,
          "expiresAt": "2100-01-01T00:00:00Z",
          "actions": [{"actionId": "refresh", "label": "Refresh", "presentation": {"tone": "neutral", "buttonRole": "neutral", "icon": "arrow.clockwise"}}]
        }
        """
        let ref = try JSONDecoder().decode(UiSurfaceRefDTO.self, from: Data(refJSON.utf8))

        #expect(ref.resourceId == "res-ui")
        #expect(ref.schemaVersion == 1)
        #expect(ref.actions?.first?.actionId == "refresh")
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
            "schemaVersion": 1,
            "layout": {"type": "Text", "props": {"text": "hello"}},
            "actions": [],
            "expiresAt": "2100-01-01T00:00:00Z"
          },
          "resourceRef": {"resourceId": "res-ui", "versionId": "ver-ui", "kind": "ui_surface", "schemaVersion": 1},
          "validationState": "valid",
          "actions": [],
          "lineage": {"versionCount": 1}
        }
        """
        let inspected = try JSONDecoder().decode(UiSurfaceInspectResultDTO.self, from: Data(inspectJSON.utf8))
        #expect(inspected.surface?.surfaceId == "surface-1")
        #expect(inspected.resourceRef?.versionId == "ver-ui")

        let validationJSON = #"{"surfaceResourceId":"res-ui","validationState":"stale","diagnostics":[{"code":"stale_surface_version"}]}"#
        let validation = try JSONDecoder().decode(UiSurfaceValidationDTO.self, from: Data(validationJSON.utf8))
        #expect(validation.validationState == "stale")

        let mutationJSON = #"{"surface":{"surfaceId":"surface-1","title":"Substrate","purpose":"Inspect","schemaVersion":1,"layout":{"type":"Text","props":{"text":"hello"}},"actions":[],"expiresAt":"2100-01-01T00:00:00Z"},"resourceRefs":[{"resourceId":"res-ui","versionId":"ver-ui","kind":"ui_surface","schemaVersion":1}]}"#
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
    }
}
