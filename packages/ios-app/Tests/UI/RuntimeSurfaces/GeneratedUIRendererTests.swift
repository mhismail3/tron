import Foundation
import Testing
@testable import TronMobile

@Suite("Generated UI Renderer")
struct GeneratedUIRendererTests {
    @Test("runtime schema supports every retained component")
    func supportsRuntimeSchemaComponents() {
        let surface = UiSurfaceDTO(
            surfaceId: "surface-components",
            title: "Components",
            purpose: "Renderer coverage",
            schemaVersion: GeneratedUIRenderer.schemaVersion,
            layout: UiComponentDTO(
                id: "root",
                type: "Section",
                props: ["title": AnyCodable("Root")],
                children: GeneratedUIRenderer.supportedComponents
                    .sorted()
                    .filter { $0 != "Section" }
                    .map { UiComponentDTO(id: $0, type: $0, props: minimalProps(for: $0), children: nil) }
            ),
            actions: [],
            expiresAt: "2100-01-01T00:00:00Z"
        )

        let state = GeneratedUIRenderer.validate(surface: surface)

        #expect(state.status == .renderable)
        #expect(state.actionsEnabled)
    }

    @Test("unsupported schema and components close instead of approximating")
    func unsupportedSchemaAndComponentsClose() {
        var surface = baseSurface(componentType: "Text")
        surface.schemaVersion = 999

        #expect(GeneratedUIRenderer.validate(surface: surface).status == .closedError("Unsupported surface schema"))

        let unsupported = baseSurface(componentType: "WebView")
        #expect(GeneratedUIRenderer.validate(surface: unsupported).status == .closedError("Unsupported UI component: WebView"))
    }

    @Test("offline, stale, expired, and damaged states disable actions")
    func closedStatesDisableActions() {
        let surface = baseSurface(componentType: "Button")
        let offline = GeneratedUIRenderer.validate(surface: surface, isOfflineCached: true)
        #expect(offline.status == .renderable)
        #expect(!offline.actionsEnabled)

        let ref = UiSurfaceRefDTO(
            resourceId: "res-ui",
            versionId: "ver-live",
            kind: "ui_surface",
            lifecycle: "active",
            surfaceId: "surface",
            title: "Surface",
            purpose: "Test",
            schemaVersion: GeneratedUIRenderer.schemaVersion,
            expiresAt: "2100-01-01T00:00:00Z",
            actions: []
        )
        let stale = GeneratedUIRenderer.validate(surface: surface, resourceRef: ref, observedVersionId: "ver-old")
        #expect(stale.status == .stale("ver-live"))
        #expect(!stale.actionsEnabled)

        var expired = surface
        expired.expiresAt = "2000-01-01T00:00:00Z"
        #expect(GeneratedUIRenderer.validate(surface: expired).status == .expired)

        var damagedRef = ref
        damagedRef.lifecycle = "damaged"
        #expect(GeneratedUIRenderer.validate(surface: surface, resourceRef: damagedRef).status == .damaged("damaged"))
    }

    @Test("server RFC3339 timestamps with fractional seconds stay renderable")
    func serverFractionalOffsetTimestampsRender() throws {
        var surface = baseSurface(componentType: "Button")
        surface.expiresAt = "2026-05-20T00:01:14.053095+00:00"
        surface.actions = [
            UiActionDTO(
                actionId: "create-note",
                label: "Create",
                inputSchema: AnyCodable(["type": "object"]),
                expiresAt: "2026-05-20T00:01:14.053095+00:00"
            )
        ]
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-19T23:01:14Z"))

        let state = GeneratedUIRenderer.validate(surface: surface, now: now)

        #expect(state.status == .renderable)
        #expect(state.actionsEnabled)
    }

    @Test("stored action input schemas scope submitted form values")
    func actionInputIsScopedToStoredSchema() {
        let action = UiActionDTO(
            actionId: "create-note",
            label: "Create",
            inputSchema: AnyCodable([
                "type": "object",
                "required": ["name", "text"],
                "additionalProperties": false,
                "properties": [
                    "name": ["type": "string"],
                    "text": ["type": "string"]
                ]
            ]),
            expiresAt: "2100-01-01T00:00:00Z"
        )
        let values: [String: AnyCodable] = [
            "name": AnyCodable("Explain"),
            "text": AnyCodable("Explain this selection"),
            "name_existing": AnyCodable("Existing"),
            "text_existing": AnyCodable("Existing body")
        ]

        #expect(GeneratedUIRenderer.inputIsSatisfied(values, for: action))
        #expect(GeneratedUIRenderer.userInput(from: values, for: action) == [
            "name": AnyCodable("Explain"),
            "text": AnyCodable("Explain this selection")
        ])

        #expect(!GeneratedUIRenderer.inputIsSatisfied([
            "name": AnyCodable("   "),
            "text": AnyCodable("Explain this selection")
        ], for: action))
    }

    @Test("agent-created runtime surface renders and submits stored coordinates")
    func agentCreatedRuntimeSurfaceRendersAndSubmitsCoordinates() throws {
        let action = UiActionDTO(
            actionId: "invoke-action",
            label: "Invoke",
            inputSchema: AnyCodable([
                "type": "object",
                "required": ["message"],
                "additionalProperties": false,
                "properties": [
                    "message": ["type": "string", "title": "Message"]
                ]
            ]),
            expiresAt: "2100-01-01T00:00:00Z",
            presentation: UiActionPresentationDTO(
                tone: "primary",
                icon: "play.fill",
                buttonRole: "primary"
            )
        )
        let surface = UiSurfaceDTO(
            surfaceId: "runtime.surface.agent-action",
            title: "Agent Action",
            purpose: "Operate an agent-created action",
            schemaVersion: GeneratedUIRenderer.schemaVersion,
            layout: UiComponentDTO(
                id: "root",
                type: "Section",
                props: ["title": AnyCodable("Agent Action")],
                children: [
                    UiComponentDTO(id: "message", type: "TextArea", props: [
                        "name": AnyCodable("message"),
                        "label": AnyCodable("Message"),
                        "required": AnyCodable(true)
                    ], children: nil),
                    UiComponentDTO(id: "invoke", type: "Button", props: [
                        "actionId": AnyCodable("invoke-action"),
                        "label": AnyCodable("Invoke")
                    ], children: nil)
                ]
            ),
            actions: [action],
            expiresAt: "2100-01-01T00:00:00Z"
        )
        let ref = UiSurfaceRefDTO(
            resourceId: "ui-surface-agent-action",
            versionId: "ver-agent-action",
            kind: "ui_surface",
            lifecycle: "active",
            surfaceId: surface.surfaceId,
            title: surface.title,
            purpose: surface.purpose,
            schemaVersion: surface.schemaVersion,
            expiresAt: surface.expiresAt,
            actions: []
        )
        let values = ["message": AnyCodable("summarize this session")]

        let state = GeneratedUIRenderer.validate(surface: surface, resourceRef: ref, observedVersionId: "ver-agent-action")
        #expect(state.status == .renderable)
        #expect(state.actionsEnabled)
        #expect(GeneratedUIRenderer.inputIsSatisfied(values, for: action))
        #expect(GeneratedUIRenderer.userInput(from: values, for: action) == values)

        let submission = UiActionSubmissionDTO(
            surfaceResourceId: ref.resourceId,
            surfaceVersionId: try #require(ref.versionId),
            actionId: action.actionId,
            userInput: GeneratedUIRenderer.userInput(from: values, for: action),
            idempotencyKey: "runtime-ui-submit"
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(submission)) as? [String: Any])
        #expect(Set(object.keys) == ["surfaceResourceId", "surfaceVersionId", "actionId", "userInput", "idempotencyKey"])
    }

    private func baseSurface(componentType: String) -> UiSurfaceDTO {
        UiSurfaceDTO(
            surfaceId: "surface",
            title: "Surface",
            purpose: "Test",
            schemaVersion: GeneratedUIRenderer.schemaVersion,
            layout: UiComponentDTO(id: "root", type: componentType, props: minimalProps(for: componentType), children: nil),
            actions: [],
            expiresAt: "2100-01-01T00:00:00Z"
        )
    }

    private func minimalProps(for component: String) -> [String: AnyCodable] {
        switch component {
        case "Text", "Heading", "Monospace", "Badge", "Warning", "Error":
            ["text": AnyCodable(component)]
        case "Section", "Disclosure":
            ["title": AnyCodable(component)]
        case "List":
            ["items": AnyCodable(["one"])]
        case "Table":
            ["rows": AnyCodable([["name": "one"]])]
        case "Tabs":
            ["tabs": AnyCodable(["one"])]
        case "ResourceRef":
            ["resourceId": AnyCodable("res")]
        case "InvocationRef":
            ["invocationId": AnyCodable("inv")]
        case "GrantRef":
            ["grantId": AnyCodable("grant")]
        case "Metric":
            ["label": AnyCodable("Metric"), "value": AnyCodable(1)]
        case "TextField", "TextArea", "Select", "Toggle", "Stepper", "DateTime":
            ["name": AnyCodable(component), "label": AnyCodable(component)]
        case "Button":
            ["actionId": AnyCodable("action"), "label": AnyCodable("Action")]
        case "ButtonGroup":
            ["actions": AnyCodable(["action"])]
        case "Confirmation":
            ["title": AnyCodable("Confirm"), "confirmActionId": AnyCodable("action")]
        case "Progress":
            ["value": AnyCodable(0.5), "total": AnyCodable(1)]
        case "Health":
            ["status": AnyCodable("healthy")]
        case "EmptyState":
            ["title": AnyCodable("Empty")]
        default:
            [:]
        }
    }
}
