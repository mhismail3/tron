import Foundation
import Testing
@testable import TronMobile

@Suite("Generated UI Renderer")
struct GeneratedUIRendererTests {
    @Test("fixed catalog supports every first-party component")
    func supportsFixedCatalog() {
        let surface = UiSurfaceDTO(
            surfaceId: "surface-components",
            title: "Components",
            purpose: "Renderer coverage",
            catalog: UiCatalogRefDTO(id: GeneratedUIRenderer.catalogId, revision: GeneratedUIRenderer.catalogRevision),
            layout: UiComponentDTO(
                id: "root",
                type: "Section",
                props: ["title": AnyCodable("Root")],
                children: GeneratedUIRenderer.supportedComponents
                    .sorted()
                    .filter { $0 != "Section" }
                    .map { UiComponentDTO(id: $0, type: $0, props: minimalProps(for: $0), children: nil) }
            ),
            bindings: [],
            actions: [],
            redactionPolicy: ["mode": AnyCodable("redacted")],
            expiresAt: "2100-01-01T00:00:00Z",
            refreshPolicy: ["mode": AnyCodable("manual")]
        )

        let state = GeneratedUIRenderer.validate(surface: surface)

        #expect(state.status == .renderable)
        #expect(state.actionsEnabled)
    }

    @Test("unsupported catalog and components close instead of approximating")
    func unsupportedCatalogAndComponentsClose() {
        var surface = baseSurface(componentType: "Text")
        surface.catalog = UiCatalogRefDTO(id: "tron.ui.catalog.other.v1", revision: 1)

        #expect(GeneratedUIRenderer.validate(surface: surface).status == .closedError("Unsupported UI catalog"))

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
            catalog: UiCatalogRefDTO(id: GeneratedUIRenderer.catalogId, revision: 1),
            expiresAt: "2100-01-01T00:00:00Z",
            targets: [],
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
                actionId: "create-snippet",
                label: "Create",
                targetFunctionId: "prompt_library::snippet_create",
                inputSchema: AnyCodable(["type": "object"]),
                payloadTemplate: AnyCodable(["name": "${input.name}", "text": "${input.text}"]),
                idempotencyKeyTemplate: "${submission.idempotencyKey}",
                requiredGrant: "prompt_library.write",
                requiredRisk: "medium",
                approvalPolicy: AnyCodable(["required": false]),
                targetRevision: 1,
                expiresAt: "2026-05-20T00:01:14.053095+00:00"
            )
        ]
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-19T23:01:14Z"))

        let state = GeneratedUIRenderer.validate(surface: surface, now: now)

        #expect(state.status == .renderable)
        #expect(state.actionsEnabled)
    }

    private func baseSurface(componentType: String) -> UiSurfaceDTO {
        UiSurfaceDTO(
            surfaceId: "surface",
            title: "Surface",
            purpose: "Test",
            catalog: UiCatalogRefDTO(id: GeneratedUIRenderer.catalogId, revision: GeneratedUIRenderer.catalogRevision),
            layout: UiComponentDTO(id: "root", type: componentType, props: minimalProps(for: componentType), children: nil),
            bindings: [],
            actions: [],
            redactionPolicy: ["mode": AnyCodable("redacted")],
            expiresAt: "2100-01-01T00:00:00Z",
            refreshPolicy: ["mode": AnyCodable("manual")]
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
        case "WorkerRef":
            ["workerId": AnyCodable("worker")]
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
