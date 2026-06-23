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
        let workerResult = snapshot.snapshot?.workerDefinitionResult()
        let functionResult = snapshot.snapshot?.functionDefinitionResult()
        let triggerResult = snapshot.snapshot?.triggerDefinitionResult()
        let triggerTypeResult = snapshot.snapshot?.triggerTypeDefinitionResult()

        #expect(snapshot.changes?.first?.kind == "worker_registered")
        #expect(workerResult?.definitions.first?.ownerActor == "system")
        #expect(workerResult?.definitions.first?.namespaceClaims == ["alpha"])
        #expect(functionResult?.definitions.first?.ownerWorker == "worker-alpha")
        #expect(functionResult?.definitions.first?.effectClass == "ExternalSideEffect")
        #expect(triggerResult?.definitions.first?.targetFunction == "alpha::run")
        #expect(triggerTypeResult?.definitions.first?.allowedDeliveryModes == ["Async"])
        #expect(workerResult?.issues.isEmpty == true)
        #expect(functionResult?.issues.isEmpty == true)
        #expect(triggerResult?.issues.isEmpty == true)
        #expect(triggerTypeResult?.issues.isEmpty == true)
    }

    @Test("Malformed catalog entries report decode diagnostics")
    func malformedCatalogEntriesReportDecodeDiagnostics() throws {
        let json = """
        {
          "snapshot": {
            "functions": [
              {
                "id": "alpha::run",
                "owner_worker": "worker-alpha",
                "request_schema": {"type": "object"},
                "response_schema": {"type": "object"}
              },
              {
                "owner_worker": "worker-broken",
                "request_schema": {"type": "object"}
              }
            ]
          }
        }
        """

        let snapshot = try JSONDecoder().decode(CatalogWatchSnapshotDTO.self, from: Data(json.utf8))
        let result = snapshot.snapshot?.functionDefinitionResult()

        #expect(result?.definitions.map(\.id) == ["alpha::run"])
        #expect(result?.issues.count == 1)
        #expect(result?.issues.first?.category == "functions")
        #expect(result?.issues.first?.index == 1)
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

    @Test("Catalog discovery report result decodes resource evidence")
    func catalogDiscoveryReportResultDecodesResourceEvidence() throws {
        let json = """
        {
          "status": "passed",
          "reportResourceId": "catalog_discovery_report:7:invocation-1",
          "streamCursor": 44,
          "summary": {"functions": {"visible": 3}},
          "resourceRefs": [
            {
              "kind": "catalog_discovery_report",
              "resourceId": "catalog_discovery_report:7:invocation-1",
              "versionId": "version-1",
              "role": "catalog_discovery_report"
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(CatalogDiscoveryReportResultDTO.self, from: Data(json.utf8))

        #expect(result.status == "passed")
        #expect(result.reportResourceId == "catalog_discovery_report:7:invocation-1")
        #expect(result.streamCursor == 44)
        #expect(result.resourceRefs?.first?.kind == WorkerLifecycleResourceKind.catalogDiscoveryReport.rawValue)
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
