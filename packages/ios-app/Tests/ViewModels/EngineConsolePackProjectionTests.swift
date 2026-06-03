import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Engine Console Pack Projection")
struct EngineConsolePackProjectionTests {
    @Test("local pack lifecycle uses product labels from server-owned action summaries")
    func localPackLifecycleUsesProductLabels() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        client.controlSnapshot = ControlSnapshotDTO(
            catalogRevision: 44,
            workers: [],
            capabilities: [],
            resourceTypes: [],
            activeGoals: [],
            modulePackages: [
                AnyCodable([
                    "resourceId": "worker-package:demo-pack",
                    "currentVersionId": "pkg-v1",
                    "lifecycle": "available"
                ]),
                AnyCodable([
                    "resourceId": "worker-package:removed-pack",
                    "currentVersionId": "pkg-v2",
                    "lifecycle": "discarded"
                ])
            ],
            moduleConfigs: [
                AnyCodable([
                    "resourceId": "module-config:workspace:demo-pack",
                    "currentVersionId": "cfg-v1",
                    "lifecycle": "active"
                ])
            ],
            activationRecords: [
                AnyCodable([
                    "resourceId": "activation:workspace:demo-pack",
                    "currentVersionId": "act-v1",
                    "lifecycle": "disabled"
                ])
            ],
            moduleHealth: [],
            moduleSourceTrust: [],
            invocations: [],
            grants: [],
            queues: [],
            leases: [],
            approvals: [],
            storage: nil,
            integrityWarnings: [],
            availableActions: [
                packAction("module::register_package", label: "Register pack", targetType: "package", targetField: "manifest", risk: "medium", approvalRequired: false, icon: "plus"),
                packAction("module::inspect_package", label: "Inspect pack", targetType: "package", targetField: "packageId", risk: "low", approvalRequired: false, icon: "magnifyingglass"),
                packAction("module::configure", label: "Configure pack", targetType: "package", targetField: "packageResourceId", risk: "medium", approvalRequired: false, icon: "slider.horizontal.3"),
                packAction("module::activate", label: "Activate pack", targetType: "package", targetField: "packageResourceId", risk: "high", approvalRequired: true, icon: "bolt.fill"),
                packAction("module::disable", label: "Disable pack", targetType: "activation", targetField: "activationResourceId", risk: "high", approvalRequired: true, icon: "pause.circle"),
                packAction("module::rollback", label: "Roll back", targetType: "activation", targetField: "activationResourceId", risk: "high", approvalRequired: true, icon: "arrow.uturn.backward"),
                packAction("module::revoke_source_approval", label: "Revoke source approval", targetType: "package", targetField: "decisionResourceId", risk: "high", approvalRequired: true, icon: "trash"),
                packAction("module::remove_package", label: "Remove pack", targetType: "package", targetField: "packageResourceId", risk: "high", approvalRequired: true, icon: "trash"),
                AnyCodable(["functionId": "worker::disconnect", "label": "Disconnect worker", "targetType": "worker"])
            ]
        )
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())

        await state.refresh()

        let projection = state.moduleOperatorProjection
        #expect(projection.cardTitle == "Packs")
        #expect(projection.cardSubtitle == "Local capability packs, trust, health, evidence, and server-authored controls.")
        #expect(projection.emptyTitle == "No packs")
        #expect(projection.packages.map(\.displayName) == ["demo-pack", "removed-pack"])
        #expect(projection.packages.map(\.lifecycleLabel) == ["Registered", "Removed"])
        #expect(projection.configs.first?.lifecycleLabel == "Configured")
        #expect(projection.activations.first?.lifecycleLabel == "Disabled")
        #expect(projection.surfaceTargets.map(\.title) == ["Pack Controls", "Pack Controls", "Activation Controls"])
        #expect(projection.surfaceTargets.first?.subtitle == "demo-pack")

        let labels = projection.actions.map(\.displayLabel)
        for required in [
            "Register pack",
            "Inspect pack",
            "Configure pack",
            "Activate pack",
            "Disable pack",
            "Roll back",
            "Revoke source approval",
            "Remove pack"
        ] {
            #expect(labels.contains(required))
        }
        #expect(!labels.contains("module::activate"))
        #expect(!projection.actions.map(\.functionId).contains("worker::disconnect"))
        #expect(projection.actions.first(where: { $0.displayLabel == "Remove pack" })?.presentationIcon == "trash")

        let packageSurface = try #require(projection.surfaceTargets.first)
        await state.authorSurface(targetType: packageSurface.targetType, targetId: packageSurface.targetId)
        #expect(client.lastSurfaceRequest?.targetType == "package")
        #expect(client.lastSurfaceRequest?.targetId == "worker-package:demo-pack")
        #expect(client.lastSurfaceRequest?.purpose == "Manage pack demo-pack")
    }

    private func packAction(
        _ functionId: String,
        label: String,
        targetType: String,
        targetField: String,
        risk: String,
        approvalRequired: Bool,
        icon: String
    ) -> AnyCodable {
        AnyCodable([
            "functionId": functionId,
            "label": label,
            "targetType": targetType,
            "targetField": targetField,
            "target": NSNull(),
            "requiredRisk": risk,
            "approvalRequired": approvalRequired,
            "state": "available",
            "presentation": ["icon": icon]
        ])
    }

    private func ephemeralCache() -> EngineConsoleCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("EngineConsoleCache.json")
        return EngineConsoleCache(fileURL: url)
    }
}
