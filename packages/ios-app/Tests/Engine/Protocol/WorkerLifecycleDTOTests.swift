import Foundation
import Testing
@testable import TronMobile

@Suite("Worker Lifecycle DTO Tests")
struct WorkerLifecycleDTOTests {
    @Test("Catalog snapshot decodes current engine worker/function/trigger shapes")
    func catalogSnapshotDecodesEngineShapes() throws {
        let json = """
        {
          "changes": [
            {
              "id": "change-1",
              "beforeRevision": 1,
              "afterRevision": 2,
              "kind": "worker_registered",
              "subjectId": "worker-alpha",
              "subjectKind": "worker",
              "class": "availability",
              "visibility": "system",
              "ownerWorker": "worker-alpha",
              "timestamp": "2026-06-14T12:00:00Z"
            }
          ],
          "snapshot": {
            "workers": [
              {
                "id": "worker-alpha",
                "revision": 3,
                "kind": "External",
                "lifecycle": "Ready",
                "owner_actor": "system",
                "authority_grant": "engine-transport",
                "namespace_claims": ["alpha"],
                "visibility": "System",
                "provenance": {"origin": "test"}
              }
            ],
            "functions": [
              {
                "id": "alpha::run",
                "revision": 4,
                "owner_worker": "worker-alpha",
                "description": "Run alpha",
                "tags": ["alpha", "run"],
                "visibility": "Agent",
                "effect_class": "ExternalSideEffect",
                "risk_level": "High",
                "health": "Healthy",
                "required_authority": {"scopes": ["alpha.run"]},
                "request_schema": {"type": "object"},
                "response_schema": {"type": "object"},
                "metadata": {"ui": "generated"}
              }
            ],
            "triggers": [
              {
                "id": "alpha-trigger",
                "revision": 5,
                "owner_worker": "worker-alpha",
                "trigger_type": "cron",
                "target_function": "alpha::run",
                "delivery_mode": "Async",
                "authority_grant": "engine-transport",
                "visibility": "System",
                "config": {"schedule": "* * * * *"}
              }
            ],
            "triggerTypes": [
              {
                "id": "cron",
                "owner_worker": "worker-alpha",
                "description": "Cron schedule",
                "allowed_delivery_modes": ["Async"],
                "visibility": "System",
                "config_schema": {"type": "object"}
              }
            ]
          },
          "currentRevision": 2,
          "nextRevision": 3,
          "hasMore": false
        }
        """

        let snapshot = try JSONDecoder().decode(CatalogWatchSnapshotDTO.self, from: Data(json.utf8))

        #expect(snapshot.changes?.first?.kind == "worker_registered")
        #expect(snapshot.snapshot?.workerDefinitions().first?.ownerActor == "system")
        #expect(snapshot.snapshot?.workerDefinitions().first?.namespaceClaims == ["alpha"])
        #expect(snapshot.snapshot?.functionDefinitions().first?.ownerWorker == "worker-alpha")
        #expect(snapshot.snapshot?.functionDefinitions().first?.effectClass == "ExternalSideEffect")
        #expect(snapshot.snapshot?.triggerDefinitions().first?.targetFunction == "alpha::run")
        #expect(snapshot.snapshot?.triggerTypeDefinitions().first?.allowedDeliveryModes == ["Async"])
    }

    @Test("Lifecycle result decodes dynamic worker token")
    func lifecycleResultDecodesWorkerToken() throws {
        let json = """
        {
          "status": "launched",
          "packageResourceId": "worker_package:alpha:1.0.0",
          "installationResourceId": "worker_package_installation:alpha:1.0.0",
          "launchAttemptResourceId": "worker_launch_attempt:alpha:123",
          "streamCursor": 42,
          "workerToken": {"pluginId": "alpha", "signatureStatus": "session_scoped"}
        }
        """

        let result = try JSONDecoder().decode(WorkerLifecycleResultDTO.self, from: Data(json.utf8))

        #expect(result.status == "launched")
        #expect(result.launchAttemptResourceId == "worker_launch_attempt:alpha:123")
        #expect(result.workerToken?["pluginId"]?.stringValue == "alpha")
    }

    @Test("Resource inspection decodes package manifest payload")
    func resourceInspectionDecodesPackageManifestPayload() throws {
        let json = """
        {
          "inspection": {
            "resource": {
              "resourceId": "worker_package_proposal:alpha:1.0.0:invocation-1",
              "kind": "worker_package_proposal",
              "schemaId": "tron.resource.worker_package_proposal.v1",
              "scope": "system",
              "ownerWorkerId": "worker",
              "ownerActorId": "system",
              "lifecycle": "proposed",
              "policy": {"owner": "worker"},
              "currentVersionId": "version-1",
              "traceId": "trace-1",
              "createdByInvocationId": "invocation-1",
              "createdAt": "2026-06-14T12:00:00Z",
              "updatedAt": "2026-06-14T12:00:00Z"
            },
            "versions": [
              {
                "versionId": "version-1",
                "resourceId": "worker_package_proposal:alpha:1.0.0:invocation-1",
                "parentVersionId": null,
                "contentHash": "hash",
                "state": "available",
                "payload": {
                  "manifest": {
                    "packageId": "alpha",
                    "packageVersion": "1.0.0",
                    "futureField": {"kept": true}
                  }
                },
                "locations": [],
                "createdByInvocationId": "invocation-1",
                "traceId": "trace-1",
                "createdAt": "2026-06-14T12:00:00Z"
              }
            ],
            "outgoingLinks": [],
            "incomingLinks": [],
            "events": []
          }
        }
        """

        let result = try JSONDecoder().decode(ResourceInspectResultDTO.self, from: Data(json.utf8))
        let payload = result.inspection?.versions.first?.payload
        let manifest = payload?["manifest"]?.dictionaryValue

        #expect(result.inspection?.resource.lifecycle == "proposed")
        #expect(manifest?["packageId"] as? String == "alpha")
        #expect((manifest?["futureField"] as? [String: Any])?["kept"] as? Bool == true)
    }
}
