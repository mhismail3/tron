//! Ordered first-party module manifest composition.
//!
//! Domain registration owns which manifests exist at startup. The engine sees
//! only generic typed resources and reconciles these source-owned payloads
//! without importing feature contracts.

mod import_update;
mod notification_delivery;
mod procedural;
mod web_research;

use serde_json::{Value, json};

use self::import_update::import_update_module_manifest;
use self::notification_delivery::notification_delivery_module_manifest;
use self::procedural::procedural_module_manifest;
use self::web_research::web_research_module_manifest;
use crate::domains::module_registry::{
    MODULE_MANIFEST_KIND, MODULE_MANIFEST_SCHEMA_ID, READ_SCOPE, RESOURCE_READ_SCOPE,
    SCHEMA_VERSION as MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION, WORKER,
};
use crate::engine::{ActorId, CreateResource, EngineResourceScope, TraceId, WorkerId};

pub(super) fn builtin_module_manifest_resources() -> Vec<CreateResource> {
    [
        module_registry_manifest(),
        capability_manifest(),
        file_git_module_manifest(),
        jobs_program_execution_module_manifest(),
        memory_engine_module_manifest(),
        procedural_module_manifest(),
        web_research_module_manifest(),
        notification_delivery_module_manifest(),
        import_update_module_manifest(),
    ]
    .into_iter()
    .map(seed_resource)
    .collect()
}

fn module_registry_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "module_registry",
            "name": "Module Registry",
            "kind": "first_party_domain",
            "owner": "domains::module_registry",
            "summary": "Inspect-only module identity and declaration registry",
            "version": "phase3-slice23a"
        },
        "capabilityDeclarations": [
            {
                "operation": "module_list",
                "effect": "read",
                "providerVisible": true,
                "description": "List bounded provider-safe module manifest summaries"
            },
            {
                "operation": "module_inspect",
                "effect": "read",
                "providerVisible": true,
                "description": "Inspect one provider-safe module manifest projection"
            }
        ],
        "resourceDeclarations": [
            {
                "kind": MODULE_MANIFEST_KIND,
                "schemaId": MODULE_MANIFEST_SCHEMA_ID,
                "payloadSchemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
                "scope": "system"
            }
        ],
        "authorityNeeds": [
            {
                "scope": READ_SCOPE,
                "purpose": "read module manifest projections"
            },
            {
                "scope": RESOURCE_READ_SCOPE,
                "purpose": "inspect system module_manifest resources"
            }
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "validated",
            "checks": [
                {
                    "id": "manifest_schema",
                    "status": "passed",
                    "summary": "Schema-bound inspect-only manifest payload"
                },
                {
                    "id": "no_side_effects",
                    "status": "passed",
                    "summary": "List and inspect do not install, activate, execute, or access networks"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-001"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::module_registry"
                }
            ]
        },
        "lifecycle": {
            "state": "validated",
            "activation": "inspect_only",
            "installable": false,
            "executable": false,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}

fn capability_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "capability",
            "name": "Capability Execute Primitive",
            "kind": "first_party_domain",
            "owner": "domains::capability",
            "summary": "Single model-facing primitive execute surface",
            "version": "phase3-slice23a"
        },
        "capabilityDeclarations": [
            {
                "operation": "execute",
                "effect": "delegated_invocation",
                "providerVisible": true,
                "description": "Runs one authorized primitive operation through capability::execute"
            }
        ],
        "resourceDeclarations": [
            {
                "kind": "trace_record",
                "schemaId": "session_event_store",
                "payloadSchemaVersion": "session.trace",
                "scope": "session"
            }
        ],
        "authorityNeeds": [
            {
                "scope": "capability.execute",
                "purpose": "execute one delegated primitive operation"
            }
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "validated",
            "checks": [
                {
                    "id": "single_model_surface",
                    "status": "passed",
                    "summary": "Providers see only the execute primitive"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-001"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::capability"
                }
            ]
        },
        "lifecycle": {
            "state": "validated",
            "activation": "core_primitive",
            "installable": false,
            "executable": true,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}

fn file_git_module_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "file_git_module",
            "name": "File And Source-Control Module Pack",
            "kind": "module_pack",
            "owner": "domains::filesystem+domains::git",
            "summary": "Governed file and source-control workflow pack through capability::execute",
            "version": "phase3-slice24a"
        },
        "capabilityDeclarations": [
            {"operation": "filesystem_read", "effect": "read", "providerVisible": true, "description": "Read bounded UTF-8 file content under the trusted working-directory root"},
            {"operation": "filesystem_list", "effect": "read", "providerVisible": true, "description": "List bounded directory entries under the trusted working-directory root"},
            {"operation": "filesystem_find", "effect": "read", "providerVisible": true, "description": "Find bounded filesystem entries under the trusted working-directory root"},
            {"operation": "filesystem_glob", "effect": "read", "providerVisible": true, "description": "Glob bounded filesystem entries under the trusted working-directory root"},
            {"operation": "filesystem_search_text", "effect": "read", "providerVisible": true, "description": "Search bounded text matches under the trusted working-directory root"},
            {"operation": "filesystem_diff", "effect": "read", "providerVisible": true, "description": "Preview bounded file diffs under the trusted working-directory root"},
            {"operation": "filesystem_write", "effect": "write", "providerVisible": true, "description": "Create patch proposal evidence and optionally materialize one file with idempotency"},
            {"operation": "filesystem_edit", "effect": "write", "providerVisible": true, "description": "Create exact-text patch proposal evidence and optionally materialize one file with idempotency"},
            {"operation": "filesystem_apply_patch", "effect": "write", "providerVisible": true, "description": "Create patch proposal evidence and optionally materialize one file with idempotency"},
            {"operation": "git_status", "effect": "read", "providerVisible": true, "description": "Read bounded repository status for the trusted working-directory repository"},
            {"operation": "git_diff", "effect": "read", "providerVisible": true, "description": "Read bounded staged and unstaged diff evidence"},
            {"operation": "git_branch_inventory", "effect": "read", "providerVisible": true, "description": "Read bounded local branch inventory evidence"},
            {"operation": "git_stage", "effect": "write", "providerVisible": true, "description": "Stage one explicit relative path into the Git index with resource evidence"},
            {"operation": "git_unstage", "effect": "write", "providerVisible": true, "description": "Unstage one explicit relative path from the Git index with resource evidence"},
            {"operation": "git_commit", "effect": "write", "providerVisible": true, "description": "Create one guarded commit from the already-staged index with resource evidence"},
            {"operation": "git_branch_start", "effect": "write", "providerVisible": true, "description": "Create and enter one local branch at expected HEAD with resource evidence"}
        ],
        "resourceDeclarations": [
            {
                "kind": "patch_proposal",
                "schemaId": "tron.resource.patch_proposal.v1",
                "payloadSchemaVersion": "tron.filesystem.patch_proposal.v1",
                "scope": "session"
            },
            {
                "kind": "materialized_file",
                "schemaId": "tron.resource.materialized_file.v1",
                "payloadSchemaVersion": "tron.filesystem.materialized_file.v1",
                "scope": "session"
            },
            {
                "kind": "git_index_change",
                "schemaId": "tron.resource.git_index_change.v1",
                "payloadSchemaVersion": "tron.git_index_change.v1",
                "scope": "session"
            },
            {
                "kind": "git_commit",
                "schemaId": "tron.resource.git_commit.v1",
                "payloadSchemaVersion": "tron.git_commit.v1",
                "scope": "session"
            },
            {
                "kind": "git_branch_start",
                "schemaId": "tron.resource.git_branch_start.v1",
                "payloadSchemaVersion": "tron.git_branch_start.v1",
                "scope": "session"
            }
        ],
        "authorityNeeds": [
            {
                "scope": "filesystem.read",
                "purpose": "read bounded file and directory evidence under trusted working-directory file roots"
            },
            {
                "scope": "filesystem.write",
                "purpose": "write reviewed patch/materialized-file resource evidence under trusted working-directory file roots"
            },
            {
                "scope": "git.read",
                "purpose": "read bounded status, diff, and branch inventory evidence for the trusted working-directory repository"
            },
            {
                "scope": "git.write",
                "purpose": "mutate only selected Git index, commit, and branch-start boundaries"
            },
            {
                "scope": "resource.read",
                "purpose": "inspect existing evidence resources when operations link to prior resource state"
            },
            {
                "scope": "resource.write",
                "purpose": "record patch, materialized-file, index-change, commit, and branch-start evidence"
            }
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "pending_review",
            "checks": [
                {
                    "id": "single_model_surface",
                    "status": "passed",
                    "summary": "The pack declares existing capability::execute operations only"
                },
                {
                    "id": "no_broad_git_expansion",
                    "status": "passed",
                    "summary": "Checkout, merge, rebase, reset, stash, fetch, pull, push, PR, and conflict workflows remain absent"
                },
                {
                    "id": "bounded_redacted_evidence",
                    "status": "implementation-candidate",
                    "summary": "Provider projections expose bounded manifest metadata and resource refs without raw paths, commands, logs, code, secrets, grants, or authority IDs"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-009"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::filesystem"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::git"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::capability"
                }
            ]
        },
        "lifecycle": {
            "state": "pending_review",
            "activation": "authority_mapped_module_pack",
            "installable": false,
            "executable": false,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}

fn jobs_program_execution_module_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "jobs_program_execution_module",
            "name": "Jobs And Program Execution Module Pack",
            "kind": "module_pack",
            "owner": "domains::jobs+domains::program_execution+domains::module_runtime",
            "summary": "Supervised non-interactive program execution through capability::execute with redacted job and output refs",
            "version": "phase3-slice24b"
        },
        "capabilityDeclarations": [
            {
                "operation": "module_program_execution_start",
                "effect": "write",
                "providerVisible": true,
                "description": "Start one enabled-lifecycle supervised job and record content-free program execution metadata"
            },
            {
                "operation": "module_program_execution_status",
                "effect": "read",
                "providerVisible": true,
                "description": "Inspect redacted runtime, job, and output custody refs for one delegated module job"
            },
            {
                "operation": "module_program_execution_cancel",
                "effect": "write",
                "providerVisible": true,
                "description": "Request cancellation through the jobs domain and update the module runtime envelope"
            },
            {
                "operation": "module_program_execution_cleanup",
                "effect": "write",
                "providerVisible": true,
                "description": "Archive a terminal delegated job with exact version freshness and record cleanup metadata"
            }
        ],
        "resourceDeclarations": [
            {
                "kind": "module_runtime_state",
                "schemaId": "tron.resource.module_runtime_state.v1",
                "payloadSchemaVersion": "tron.module_runtime_state.v1",
                "scope": "session"
            },
            {
                "kind": "module_lifecycle_state",
                "schemaId": "tron.resource.module_lifecycle_state.v1",
                "payloadSchemaVersion": "tron.module_lifecycle_state.v1",
                "scope": "session"
            },
            {
                "kind": "program_execution_record",
                "schemaId": "tron.resource.program_execution_record.v1",
                "payloadSchemaVersion": "tron.program_execution_record.v1",
                "scope": "session"
            },
            {
                "kind": "job_process",
                "schemaId": "tron.resource.job_process.v1",
                "payloadSchemaVersion": "tron.job_process.v1",
                "scope": "session"
            },
            {
                "kind": "execution_output",
                "schemaId": "tron.resource.execution_output.v1",
                "payloadSchemaVersion": "tron.execution_output.v1",
                "scope": "session"
            }
        ],
        "authorityNeeds": [
            {
                "scope": "module_runtime.read",
                "purpose": "inspect runtime envelope refs and freshness"
            },
            {
                "scope": "module_runtime.write",
                "purpose": "record delegated job supervision state and cancellation or cleanup metadata"
            },
            {
                "scope": "program_execution.read",
                "purpose": "link metadata-only program execution evidence"
            },
            {
                "scope": "program_execution.write",
                "purpose": "record content-free runtime/language/fingerprint evidence"
            },
            {
                "scope": "jobs.read",
                "purpose": "inspect redacted delegated job state"
            },
            {
                "scope": "jobs.write",
                "purpose": "start, cancel, and archive the delegated non-interactive job"
            },
            {
                "scope": "resource.read",
                "purpose": "inspect exact lifecycle, runtime, job, and output resource refs"
            },
            {
                "scope": "resource.write",
                "purpose": "record runtime, program, job, and output resource updates"
            }
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "pending_review",
            "checks": [
                {
                    "id": "single_model_surface",
                    "status": "passed",
                    "summary": "The pack is available only through capability::execute module_program_execution operations"
                },
                {
                    "id": "bounded_output_custody",
                    "status": "implementation-candidate",
                    "summary": "Provider-visible results expose refs, fingerprints, truncation, duration, exit, timeout, cancellation, and cleanup metadata only"
                },
                {
                    "id": "no_raw_process_material",
                    "status": "passed",
                    "summary": "Manifest and projections do not expose process_run, raw job payloads, commands, code, stdin, stdout, stderr, logs, paths, env, pids, grant ids, PTYs, package installs, or network execution"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-010"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::jobs"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::program_execution"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::module_runtime"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::capability"
                }
            ]
        },
        "lifecycle": {
            "state": "pending_review",
            "activation": "authority_mapped_module_pack",
            "installable": false,
            "executable": false,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}

fn memory_engine_module_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "memory_engine_module",
            "name": "Memory Retrieval And Retention Module Pack",
            "kind": "module_pack",
            "owner": "domains::memory",
            "summary": "Deterministic resource-backed memory retrieval, retention evidence, and prompt inclusion proof",
            "version": "phase3-slice24d"
        },
        "capabilityDeclarations": [
            {"operation": "memory_status", "effect": "read", "providerVisible": true, "description": "Inspect memory mode, engine identity, prompt policy, and retrieval contract"},
            {"operation": "memory_list", "effect": "read", "providerVisible": true, "description": "List redacted current-session memory records with previews only"},
            {"operation": "memory_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one redacted memory record and version history"},
            {"operation": "memory_query_list", "effect": "read", "providerVisible": true, "description": "List deterministic memory query and retrieval result evidence"},
            {"operation": "memory_query_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one memory query/result evidence resource"},
            {"operation": "memory_decision_list", "effect": "read", "providerVisible": true, "description": "List memory prompt-inclusion and retention decision evidence"},
            {"operation": "memory_decision_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one memory decision evidence resource"}
        ],
        "resourceDeclarations": [
            {"kind": "memory_engine", "schemaId": "tron.resource.memory_engine.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "system"},
            {"kind": "memory_policy", "schemaId": "tron.resource.memory_policy.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace_or_system"},
            {"kind": "memory_record", "schemaId": "tron.resource.memory_record.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace"},
            {"kind": "memory_query", "schemaId": "tron.resource.memory_query.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace"},
            {"kind": "memory_decision", "schemaId": "tron.resource.memory_decision.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace"},
            {"kind": "memory_prompt_trace", "schemaId": "tron.resource.memory_prompt_trace.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace"}
        ],
        "authorityNeeds": [
            {"scope": "memory.read", "purpose": "inspect redacted memory policy, record, query, and decision projections"},
            {"scope": "memory.write", "purpose": "record retention, retrieval, prompt trace, and decision evidence through memory-owned functions"},
            {"scope": "resource.read", "purpose": "inspect exact memory resources and versions"},
            {"scope": "resource.write", "purpose": "record memory query, decision, prompt trace, and record lifecycle evidence"}
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "pending_review",
            "checks": [
                {
                    "id": "deterministic_retrieval",
                    "status": "implementation-candidate",
                    "summary": "Retrieval uses existing memory_record refs and previews only, with deterministic ranking and no embeddings"
                },
                {
                    "id": "prompt_inclusion_proof",
                    "status": "implementation-candidate",
                    "summary": "Prompt inclusion requires explicit bounded_snippets policy and records query, decision, and prompt trace evidence"
                },
                {
                    "id": "retention_audit",
                    "status": "implementation-candidate",
                    "summary": "Retain, edit, import, and tombstone record policy evidence while hard delete and automatic retention fail closed"
                },
                {
                    "id": "provider_redaction",
                    "status": "passed",
                    "summary": "Provider projections expose bounded refs and previews without raw bodies, generated summaries, paths, secrets, grants, or authority ids"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-012"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::memory"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::capability"
                }
            ]
        },
        "lifecycle": {
            "state": "pending_review",
            "activation": "authority_mapped_module_pack",
            "installable": false,
            "executable": false,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}

pub(super) fn redaction_proof() -> Value {
    json!({
        "localPaths": "absent",
        "environmentValues": "absent",
        "commands": "absent",
        "sensitiveValues": "absent",
        "grantIdentifiers": "absent",
        "authorityIdentifiers": "absent",
        "tokenLikeMaterial": "absent",
        "personalInfoLiterals": "absent"
    })
}

fn seed_resource(payload: Value) -> CreateResource {
    let module_id = payload["identity"]["moduleId"]
        .as_str()
        .expect("seed module id");
    CreateResource {
        resource_id: Some(format!("{MODULE_MANIFEST_KIND}:{module_id}")),
        kind: MODULE_MANIFEST_KIND.to_owned(),
        schema_id: Some(MODULE_MANIFEST_SCHEMA_ID.to_owned()),
        scope: EngineResourceScope::System,
        owner_worker_id: WorkerId::new(WORKER).expect("valid static worker id"),
        owner_actor_id: ActorId::new(format!("system:{WORKER}")).expect("valid static actor id"),
        lifecycle: Some("validated".to_owned()),
        policy: json!({
            "owner": WORKER,
            "authority": READ_SCOPE,
            "activation": "forbidden",
            "networkPolicy": "none"
        }),
        initial_payload: Some(payload),
        locations: Vec::new(),
        trace_id: TraceId::new("bootstrap").expect("valid static trace id"),
        invocation_id: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{EngineHostHandle, UpdateResource};

    #[tokio::test]
    async fn sqlite_reconciliation_creates_and_versions_domain_manifests() {
        let directory = tempfile::tempdir().expect("tempdir");
        let database = directory.path().join("engine.sqlite");
        let resource_id = "module_manifest:notification_delivery_module";
        let host = EngineHostHandle::open_sqlite(&database).expect("initial host");

        assert!(
            host.inspect_resource(resource_id)
                .await
                .expect("inspect bare engine")
                .is_none(),
            "bare engine construction must not compose domain manifests"
        );
        crate::domains::registration::install_module_manifests_for_test(&host)
            .expect("initial domain manifest installation");

        let inspection = host
            .inspect_resource(resource_id)
            .await
            .expect("inspect canonical manifest")
            .expect("canonical manifest exists");
        let current_version_id = inspection
            .resource
            .current_version_id
            .expect("canonical current version");
        let mut stale_payload = inspection
            .versions
            .iter()
            .find(|version| version.version_id == current_version_id)
            .expect("canonical current payload")
            .payload
            .clone();
        stale_payload["capabilityDeclarations"]
            .as_array_mut()
            .expect("capability declarations")
            .insert(
                2,
                json!({
                    "operation": "device_register",
                    "effect": "write",
                    "providerVisible": false,
                    "description": "stale declaration"
                }),
            );
        let stale_version_id = host
            .update_resource(UpdateResource {
                resource_id: resource_id.to_owned(),
                expected_current_version_id: Some(current_version_id),
                lifecycle: None,
                payload: stale_payload,
                state: None,
                locations: Vec::new(),
                trace_id: TraceId::new("test-stale-seed").expect("trace id"),
                invocation_id: None,
            })
            .await
            .expect("write stale manifest")
            .version_id;
        drop(host);

        let reopened = EngineHostHandle::open_sqlite(&database).expect("reopened host");
        super::super::install_module_manifest_resources(&reopened)
            .await
            .expect("install source-owned manifests");
        let inspection = reopened
            .inspect_resource(resource_id)
            .await
            .expect("inspect reconciled manifest")
            .expect("reconciled manifest exists");
        let current_version_id = inspection
            .resource
            .current_version_id
            .expect("reconciled current version");
        assert_ne!(current_version_id, stale_version_id);
        assert_eq!(
            inspection.versions.len(),
            3,
            "version history must be retained"
        );
        let current_payload = &inspection
            .versions
            .iter()
            .find(|version| version.version_id == current_version_id)
            .expect("reconciled current payload")
            .payload;
        assert!(
            current_payload["capabilityDeclarations"]
                .as_array()
                .expect("capability declarations")
                .iter()
                .all(|declaration| declaration["operation"] != json!("device_register"))
        );

        super::super::install_module_manifest_resources(&reopened)
            .await
            .expect("repeat source-owned manifest installation");
        let repeated = reopened
            .inspect_resource(resource_id)
            .await
            .expect("inspect repeated reconciliation")
            .expect("reconciled manifest remains");
        assert_eq!(
            repeated.versions.len(),
            3,
            "an equal canonical payload must not append another version"
        );
    }
}
