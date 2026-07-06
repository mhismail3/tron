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
                "ownerActor": "system",
                "authorityGrant": "engine-transport",
                "namespaceClaims": ["alpha"],
                "visibility": "System",
                "provenance": {"origin": "test"}
              }
            ],
            "functions": [
              {
                "id": "alpha::run",
                "revision": 4,
                "ownerWorker": "worker-alpha",
                "description": "Run alpha",
                "tags": ["alpha", "run"],
                "visibility": "Agent",
                "effectClass": "ExternalSideEffect",
                "riskLevel": "High",
                "health": "Healthy",
                "requiredAuthority": {"scopes": ["alpha.run"]},
                "requestSchema": {"type": "object"},
                "responseSchema": {"type": "object"},
                "metadata": {"ui": "generated"}
              }
            ],
            "triggers": [
              {
                "id": "alpha-trigger",
                "revision": 5,
                "ownerWorker": "worker-alpha",
                "triggerType": "cron",
                "targetFunction": "alpha::run",
                "deliveryMode": "Async",
                "authorityGrant": "engine-transport",
                "visibility": "System",
                "config": {"schedule": "* * * * *"}
              }
            ],
            "triggerTypes": [
              {
                "id": "cron",
                "ownerWorker": "worker-alpha",
                "description": "Cron schedule",
                "allowedDeliveryModes": ["Async"],
                "visibility": "System",
                "configSchema": {"type": "object"}
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

    @Test("Catalog snapshot decodes server snake-case catalog definitions")
    func catalogSnapshotDecodesServerSnakeCaseDefinitions() throws {
        let json = """
        {
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
                "opaque_response": false,
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
          }
        }
        """

        let snapshot = try JSONDecoder().decode(CatalogWatchSnapshotDTO.self, from: Data(json.utf8))
        let workerResult = snapshot.snapshot?.workerDefinitionResult()
        let functionResult = snapshot.snapshot?.functionDefinitionResult()
        let triggerResult = snapshot.snapshot?.triggerDefinitionResult()
        let triggerTypeResult = snapshot.snapshot?.triggerTypeDefinitionResult()

        #expect(workerResult?.definitions.first?.ownerActor == "system")
        #expect(workerResult?.definitions.first?.authorityGrant == "engine-transport")
        #expect(workerResult?.definitions.first?.namespaceClaims == ["alpha"])
        #expect(functionResult?.definitions.first?.ownerWorker == "worker-alpha")
        #expect(functionResult?.definitions.first?.effectClass == "ExternalSideEffect")
        #expect(functionResult?.definitions.first?.riskLevel == "High")
        #expect(functionResult?.definitions.first?.requiredAuthority?["scopes"]?.arrayValue?.count == 1)
        #expect(functionResult?.definitions.first?.requestSchema != nil)
        #expect(functionResult?.definitions.first?.responseSchema != nil)
        #expect(functionResult?.definitions.first?.opaqueResponse == false)
        #expect(triggerResult?.definitions.first?.ownerWorker == "worker-alpha")
        #expect(triggerResult?.definitions.first?.triggerType == "cron")
        #expect(triggerResult?.definitions.first?.targetFunction == "alpha::run")
        #expect(triggerResult?.definitions.first?.deliveryMode == "Async")
        #expect(triggerResult?.definitions.first?.authorityGrant == "engine-transport")
        #expect(triggerTypeResult?.definitions.first?.ownerWorker == "worker-alpha")
        #expect(triggerTypeResult?.definitions.first?.allowedDeliveryModes == ["Async"])
        #expect(triggerTypeResult?.definitions.first?.configSchema != nil)
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
                "ownerWorker": "worker-alpha",
                "requestSchema": {"type": "object"},
                "responseSchema": {"type": "object"}
              },
              {
                "ownerWorker": "worker-broken",
                "requestSchema": {"type": "object"}
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

    @Test("Capability cockpit overview decodes server-owned truth fields")
    func capabilityCockpitOverviewDecodesServerProjectionTruth() throws {
        let json = """
        {
          "schemaVersion": "tron.capability_binding.cockpit_overview.v1",
          "operation": "capability_binding_cockpit_overview",
          "summary": {
            "totalOperations": 181,
            "returnedOperations": 1,
            "operationListComplete": false,
            "operationListTruncated": true,
            "resourceScanComplete": false,
            "resourceScanTruncated": true,
            "kernelLocked": 1,
            "governanceLocked": 0,
            "recordPlane": 0,
            "adapterReplaceable": 1,
            "moduleOwned": 0,
            "deferred": 0,
            "bindingRequests": 100,
            "bindingApproved": 0,
            "bindingRejected": 1,
            "activePolicies": 0,
            "shadowRequests": 1,
            "shadowRuns": 1,
            "rollbackAvailable": 1,
            "title": "Capability ownership visible",
            "detail": "1 of 181 operations returned; resource counts are bounded lower-bound facts"
          },
          "operationList": {
            "totalOperations": 181,
            "returnedOperations": 1,
            "requestedLimit": 1,
            "complete": false,
            "truncated": true,
            "state": "truncated",
            "label": "Operation list truncated",
            "detail": "1 of 181 operations are returned because the client requested limit 1."
          },
          "resourceScan": {
            "queries": 14,
            "scannedResources": 100,
            "appliedResources": 100,
            "limitPerKindScope": 100,
            "complete": false,
            "truncated": true,
            "truncatedQueries": 1,
            "state": "bounded_degraded",
            "label": "Resource scan bounded",
            "detail": "1 of 14 kind/scope scans reached the per-scan limit of 100; binding and shadow counts are lower-bound facts."
          },
          "families": [],
          "operations": [
            {
              "name": "git_status",
              "family": "git",
              "familyLabel": "Git",
              "owner": {
                "label": "Built-in Git adapter",
                "detail": "A built-in adapter owns execution today and can be proposed for governed replacement later.",
                "source": "capability execute registry redacted ownership metadata plus scoped capability binding resources",
                "metadataSourceLabel": "Capability execute registry",
                "projectionSourceLabel": "Capability binding cockpit projection"
              },
              "status": {
                "kind": "built_in_adapter",
                "label": "Built-in adapter",
                "detail": "Built-in execution can be shadowed or replaced only after governed evidence. Family: Git.",
                "builtIn": true,
                "moduleOwned": false,
                "locked": false
              },
              "replacement": {
                "canShadow": true,
                "canReplace": true,
                "canExtend": true,
                "label": "Shadow or replace after review",
                "detail": "Future modules can request shadow or replacement with exact authority, parity evidence, and rollback/disable metadata. Area: Git.",
                "target": {
                  "label": "Governed Git adapter",
                  "detail": "Any future target must satisfy exact authority, parity evidence, bounded provider-safe refs, replay/idempotency proof, and rollback/disable metadata."
                },
                "governanceBoundary": "capability binding policy"
              },
              "readiness": {
                "state": "needs_governance_review",
                "label": "Review needed",
                "detail": "Server-derived readiness only.",
                "nextActionLabel": "Inspect decisions",
                "nextActionDetail": "Do not infer readiness locally."
              },
              "binding": {
                "requested": 100,
                "approved": 0,
                "rejected": 1,
                "activePolicies": 0,
                "failedReplacementAttempts": 1,
                "latestState": "rejected",
                "lastUpdatedAt": "2026-06-27T12:00:00Z",
                "detail": "1 binding decision rejected; no runtime routing changed."
              },
              "shadowTrial": {
                "requested": 1,
                "approved": 1,
                "rejected": 0,
                "runs": 1,
                "passed": 1,
                "failed": 0,
                "aborted": 0,
                "disabled": 0,
                "latestState": "passed",
                "lastUpdatedAt": "2026-06-27T12:00:00Z",
                "availableForThisOperation": true,
                "detail": "1 metadata-only shadow run recorded; candidate execution and routing stayed disabled."
              },
              "rollback": {
                "available": true,
                "disableAvailable": true,
                "abortAvailable": true,
                "boundary": "capability binding governance",
                "detail": "Rollback metadata is available for the recorded policy or shadow trial; live routing still has not changed."
              }
            }
          ],
          "scope": {
            "sessionScoped": true,
            "workspaceScoped": true,
            "exactScopeRequired": true,
            "source": "trusted invocation causal context"
          },
          "projection": {
            "allowlist": "capability_binding_cockpit_visibility_redacted_v1",
            "serverOwnedTruth": true,
            "projectionOnly": true,
            "metadataOnly": true,
            "autonomyBehaviorCreated": false,
            "runtimeRoutingChanged": false,
            "dispatchTableMutated": false,
            "hotSwapPerformed": false,
            "moduleActivated": false,
            "moduleExecuted": false,
            "rawResourceIdsReturned": false,
            "rawLocalPathsReturned": false,
            "rawEnvValuesReturned": false,
            "rawSecretsReturned": false,
            "rawCommandsReturned": false,
            "rawLogsReturned": false,
            "rawCodeReturned": false,
            "rawFileContentsReturned": false,
            "rawGrantIdsReturned": false,
            "rawAuthorityIdsReturned": false,
            "traceIdsReturned": false,
            "invocationIdsReturned": false,
            "tokenLikeMaterialReturned": false,
            "hiddenChainOfThoughtReturned": false,
            "boundedItems": true
          }
        }
        """

        let overview = try JSONDecoder().decode(CapabilityCockpitOverviewDTO.self, from: Data(json.utf8))

        #expect(overview.summary.totalOperations == 181)
        #expect(overview.summary.returnedOperations == 1)
        #expect(overview.operationList.truncated == true)
        #expect(overview.resourceScan.state == "bounded_degraded")
        #expect(overview.operations.first?.owner.metadataSourceLabel == "Capability execute registry")
        #expect(overview.operations.first?.replacement.target.label == "Governed Git adapter")
        #expect(overview.operations.first?.readiness.nextActionLabel == "Inspect decisions")
        #expect(overview.projection.runtimeRoutingChanged == false)
    }

    @Test("Agent briefing overview decodes server-owned projection")
    func agentBriefingOverviewDecodesServerProjection() throws {
        let json = """
        {
          "schemaVersion": "tron.agent_briefing.overview.v1",
          "operation": "agent_briefing_overview",
          "summary": {
            "title": "Tron has active work",
            "detail": "1 active, 0 waiting on review, 0 blocked, 1 total records.",
            "activeWorkCount": 1,
            "needsYouCount": 0,
            "weakPointCount": 0,
            "activityCount": 1,
            "degraded": false
          },
          "sections": [
            {
              "id": "active_work",
              "title": "Active work",
              "question": "What is currently in motion?",
              "narrative": "Active module runtime work is in progress.",
              "items": [
                {
                  "id": "briefing-item-1",
                  "title": "Runtime envelope",
                  "detail": "Server-owned projection",
                  "status": "active",
                  "evidence": {
                    "label": "Evidence 1",
                    "resourceKind": "module_runtime_state",
                    "updatedAt": "2026-06-20T12:00:00Z",
                    "providerSafe": true
                  }
                }
              ],
              "emptyState": "No active work is in progress.",
              "drilldownAvailable": true
            }
          ],
          "scope": {
            "sessionScoped": true,
            "workspaceScoped": false,
            "exactScopeRequired": true,
            "payloadScopeTrusted": false
          },
          "projection": {
            "allowlist": "agent_briefing_metadata_redacted_v1",
            "serverOwnedTruth": true,
            "projectionOnly": true,
            "autonomyBehaviorCreated": false,
            "metadataOnly": true,
            "rawPayloadsReturned": false,
            "rawCommandsReturned": false,
            "rawLogsReturned": false,
            "promptBodiesReturned": false,
            "fileContentsReturned": false,
            "absolutePathsReturned": false,
            "grantIdsReturned": false,
            "authorityIdsReturned": false,
            "traceIdsReturned": false,
            "invocationIdsReturned": false,
            "tokenLikeMaterialReturned": false,
            "boundedItems": true,
            "sourceProjection": "module_activity_overview"
          }
        }
        """

        let overview = try JSONDecoder().decode(AgentBriefingOverviewDTO.self, from: Data(json.utf8))

        #expect(overview.operation == "agent_briefing_overview")
        #expect(overview.summary.activeWorkCount == 1)
        #expect(overview.sections.first?.id == "active_work")
        #expect(overview.sections.first?.items.first?.evidence?.providerSafe == true)
        #expect(overview.projection.autonomyBehaviorCreated == false)
        #expect(overview.projection.rawCommandsReturned == false)
    }

    @Test("Module activity overview ignores future product-specific fields")
    func moduleActivityOverviewIgnoresFutureProductSpecificFields() throws {
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
          "unknownProductPanel": {"panel": "fixed"},
          "unknownProductPayload": {"table": "product_state"}
        }
        """

        let overview = try JSONDecoder().decode(ModuleActivityOverviewDTO.self, from: Data(json.utf8))
        #expect(overview.schemaVersion == "tron.module_activity.overview.v1")
        #expect(overview.timeline.first?.status == "waiting")
        #expect(overview.timeline.first?.runtimeAuthorizationStatus.waiting == true)

        let encoded = try JSONEncoder().encode(overview)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let projection = try #require(object["projection"] as? [String: Any])
        #expect(object["unknownProductPanel"] == nil)
        #expect(object["unknownProductPayload"] == nil)
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
