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

    @Test("Module activity overview decodes server-owned cockpit projection")
    func moduleActivityOverviewDecodesServerProjection() throws {
        let json = """
        {
          "schemaVersion": "tron.module_activity.overview.v1",
          "operation": "module_activity_overview",
          "summary": {
            "total": 1,
            "active": 1,
            "waiting": 0,
            "blocked": 0,
            "ready": 0,
            "recorded": 0,
            "title": "Module work active",
            "detail": "1 module runtime activities are active."
          },
          "timeline": [
            {
              "id": "module_runtime_state:version-1",
              "resourceId": "module_runtime_state:runtime-1",
              "resourceKind": "module_runtime_state",
              "status": "active",
              "state": "running",
              "title": "Runtime envelope",
              "detail": "Server-owned projection",
              "authorityLabels": ["grant redacted"],
              "touchedResources": [
                {"label": "output refs", "total": 1, "truncated": false}
              ],
              "rollbackStatus": {"label": "Rollback", "state": "not_declared", "blocked": false, "waiting": false},
              "quarantineStatus": {"label": "Quarantine", "state": "clear", "blocked": false, "waiting": false},
              "runtimeAuthorizationStatus": {"label": "Runtime authorization", "state": "allowed", "blocked": false, "waiting": false},
              "updatedAt": "2026-06-20T12:00:00Z"
            }
          ],
          "blocked": [],
          "waiting": [],
          "resources": [
            {"kind": "module_runtime_state", "total": 1, "active": 1, "waiting": 0, "blocked": 0}
          ],
          "projection": {
            "allowlist": "module_activity_cockpit_metadata_redacted_v1",
            "serverOwnedTruth": true,
            "metadataOnly": true,
            "rawPayloadsReturned": false,
            "rawCommandsReturned": false,
            "rawLogsReturned": false,
            "fileContentsReturned": false,
            "absolutePathsReturned": false,
            "grantIdsReturned": false,
            "authorityIdsReturned": false,
            "traceIdsReturned": false,
            "invocationIdsReturned": false,
            "tokenLikeMaterialReturned": false,
            "boundedItems": true
          }
        }
        """

        let overview = try JSONDecoder().decode(ModuleActivityOverviewDTO.self, from: Data(json.utf8))

        #expect(overview.operation == "module_activity_overview")
        #expect(overview.summary.active == 1)
        #expect(overview.timeline.first?.status == "active")
        #expect(overview.timeline.first?.authorityLabels == ["grant redacted"])
        #expect(overview.projection.serverOwnedTruth == true)
        #expect(overview.projection.rawPayloadsReturned == false)
    }

    @Test("Module activity overview ignores future fields without product fallback")
    func moduleActivityOverviewIgnoresFutureFieldsWithoutProductFallback() throws {
        let json = """
        {
          "schemaVersion": "tron.module_activity.overview.v1",
          "operation": "module_activity_overview",
          "summary": {
            "total": 1,
            "active": 0,
            "waiting": 1,
            "blocked": 0,
            "ready": 0,
            "recorded": 1,
            "title": "Module work waiting",
            "detail": "1 module runtime activity is waiting.",
            "futureSummaryHint": {"style": "compact"}
          },
          "timeline": [
            {
              "id": "module_runtime_state:version-2",
              "resourceId": "module_runtime_state:runtime-2",
              "resourceKind": "module_runtime_state",
              "status": "waiting",
              "state": "awaiting_authority",
              "title": "Runtime envelope",
              "detail": "Server-owned projection",
              "authorityLabels": ["grant redacted"],
              "touchedResources": [
                {"label": "output refs", "total": 0, "truncated": false, "futureCountLabel": "none"}
              ],
              "rollbackStatus": {"label": "Rollback", "state": "not_declared", "blocked": false, "waiting": false},
              "quarantineStatus": {"label": "Quarantine", "state": "clear", "blocked": false, "waiting": false},
              "runtimeAuthorizationStatus": {"label": "Runtime authorization", "state": "waiting", "blocked": false, "waiting": true},
              "updatedAt": "2026-06-20T12:00:00Z",
              "futureWorkflowRef": {"resourceId": "module_dependency_request:1"}
            }
          ],
          "blocked": [],
          "waiting": [],
          "resources": [
            {"kind": "module_runtime_state", "total": 1, "active": 0, "waiting": 1, "blocked": 0}
          ],
          "projection": {
            "allowlist": "module_activity_cockpit_metadata_redacted_v1",
            "serverOwnedTruth": true,
            "metadataOnly": true,
            "rawPayloadsReturned": false,
            "rawCommandsReturned": false,
            "rawLogsReturned": false,
            "fileContentsReturned": false,
            "absolutePathsReturned": false,
            "grantIdsReturned": false,
            "authorityIdsReturned": false,
            "traceIdsReturned": false,
            "invocationIdsReturned": false,
            "tokenLikeMaterialReturned": false,
            "boundedItems": true,
            "futureProjectionPolicy": "ignored"
          },
          "productDashboard": {"panel": "legacy"},
          "productDTO": {"table": "legacy_product_state"}
        }
        """

        let overview = try JSONDecoder().decode(ModuleActivityOverviewDTO.self, from: Data(json.utf8))
        #expect(overview.schemaVersion == "tron.module_activity.overview.v1")
        #expect(overview.timeline.first?.status == "waiting")
        #expect(overview.timeline.first?.runtimeAuthorizationStatus.waiting == true)

        let encoded = try JSONEncoder().encode(overview)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let projection = try #require(object["projection"] as? [String: Any])
        #expect(object["productDashboard"] == nil)
        #expect(object["productDTO"] == nil)
        #expect(projection["futureProjectionPolicy"] == nil)
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
