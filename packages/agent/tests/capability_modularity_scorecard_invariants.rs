//! Static invariants for the capability modularity scorecard.
//!
//! The scorecard is intentionally boundary-first: it classifies current
//! operations and locks the kernel/governance substrate before any replacement
//! route can be trusted. These tests make sure the documentation stays complete
//! and prevents accidental replacement semantics from sneaking into kernel or
//! governance operations.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

const SCORECARD_PATH: &str = "packages/agent/docs/capability-modularity-scorecard.md";
const INVENTORY_PATH: &str = "packages/agent/docs/capability-modularity-inventory.tsv";
const EVIDENCE_PATH: &str = "packages/agent/docs/capability-modularity-evidence-manifest.md";
const REGISTRY_PATH: &str =
    "packages/agent/src/domains/capability/operations/operation_contract/mod.rs";
const DISPATCH_PATH: &str = "packages/agent/src/domains/capability/operations/dispatch.rs";
const README_PATH: &str = "README.md";
const EXPECTED_OPERATION_COUNT: usize = 188;

const INVENTORY_HEADER: &str = "operation\tfamily\tcurrentOwner\townershipClass\treplacementTarget\tcontractScore\tauthorityScore\tevidenceScore\tproviderSafetyScore\treplayScore\tbindingScore\trollbackScore\tvisibilityScore\ttestScore\tnextAction";

const SCORE_FIELDS: [&str; 9] = [
    "contractScore",
    "authorityScore",
    "evidenceScore",
    "providerSafetyScore",
    "replayScore",
    "bindingScore",
    "rollbackScore",
    "visibilityScore",
    "testScore",
];

const OWNERSHIP_CLASSES: [&str; 6] = [
    "kernel_locked",
    "governance_locked",
    "record_plane",
    "adapter_replaceable",
    "module_owned",
    "deferred",
];

const NEXT_ACTIONS: [&str; 7] = [
    "none",
    "document",
    "add_tests",
    "add_adapter_seam",
    "add_binding_policy",
    "split_kernel",
    "shadow_trial",
];

#[derive(Debug)]
struct InventoryRow {
    operation: String,
    family: String,
    current_owner: String,
    ownership_class: String,
    replacement_target: String,
    scores: BTreeMap<&'static str, u8>,
    next_action: String,
}

struct SourceRequirement {
    path: &'static str,
    markers: &'static [&'static str],
}

struct KernelBoundaryArea {
    area: &'static str,
    source: &'static [SourceRequirement],
    locked_families: &'static [&'static str],
    locked_operations: &'static [&'static str],
    allowed_classes: &'static [&'static str],
}

struct AdapterSeamArea {
    family: &'static str,
    operations: &'static [&'static str],
    source: &'static [SourceRequirement],
    inventory_markers: &'static [&'static str],
    docs_markers: &'static [&'static str],
    record_plane_strategy: bool,
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn registry_operations() -> Vec<String> {
    let registry = read_repo_file(REGISTRY_PATH);
    let mut in_registry = false;
    let mut operations = Vec::new();
    for line in registry.lines() {
        if line.trim() == "define_operation_ids! {" {
            in_registry = true;
            continue;
        }
        if in_registry && line.trim() == "}" {
            break;
        }
        if !in_registry {
            continue;
        }
        let trimmed = line.trim();
        if trimmed.contains("=> \"") {
            let operation = trimmed
                .split('"')
                .nth(1)
                .unwrap_or_else(|| panic!("registry operation row is malformed: {line}"));
            operations.push(operation.to_owned());
        }
    }
    operations
}

fn dispatch_operations() -> Vec<String> {
    let dispatch = read_repo_file(DISPATCH_PATH);
    let registry = read_repo_file(REGISTRY_PATH);
    let names_by_variant: BTreeMap<_, _> = registry
        .lines()
        .skip_while(|line| line.trim() != "define_operation_ids! {")
        .skip(1)
        .take_while(|line| line.trim() != "}")
        .filter_map(|line| {
            let (variant, name) = line.trim().split_once(" => \"")?;
            Some((variant.to_owned(), name.trim_end_matches("\",").to_owned()))
        })
        .collect();
    let mut in_match = false;
    let mut operations = Vec::new();
    for line in dispatch.lines() {
        if line.contains("Ok(match operation {") {
            in_match = true;
            continue;
        }
        if in_match && line.trim() == "})" {
            break;
        }
        if !in_match {
            continue;
        }
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("OperationId::") {
            let variant = rest
                .split_whitespace()
                .next()
                .unwrap_or_else(|| panic!("dispatch operation row is malformed: {line}"));
            let name = names_by_variant
                .get(variant)
                .unwrap_or_else(|| panic!("dispatch variant is not registered: {variant}"));
            operations.push(name.clone());
        }
    }
    operations
}

fn parse_inventory() -> Vec<InventoryRow> {
    let inventory = read_repo_file(INVENTORY_PATH);
    let mut lines = inventory.lines();
    assert_eq!(
        lines.next(),
        Some(INVENTORY_HEADER),
        "capability modularity inventory header drifted"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                15,
                "inventory row must have 15 tab-separated columns: {line}"
            );
            let mut scores = BTreeMap::new();
            for (offset, field) in SCORE_FIELDS.iter().enumerate() {
                let score = columns[5 + offset]
                    .parse::<u8>()
                    .unwrap_or_else(|error| panic!("{field} must be numeric in {line}: {error}"));
                assert!(score <= 3, "{field} must be between 0 and 3 in {line}");
                scores.insert(*field, score);
            }
            InventoryRow {
                operation: columns[0].to_owned(),
                family: columns[1].to_owned(),
                current_owner: columns[2].to_owned(),
                ownership_class: columns[3].to_owned(),
                replacement_target: columns[4].to_owned(),
                scores,
                next_action: columns[14].to_owned(),
            }
        })
        .collect()
}

fn duplicate_values(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut duplicate = BTreeSet::new();
    for value in values {
        if !seen.insert(value.clone()) {
            duplicate.insert(value.clone());
        }
    }
    duplicate.into_iter().collect()
}

fn expected_family_and_class(operation: &str) -> (&'static str, &'static str) {
    match operation {
        "observe" | "replay_manifest" => ("core", "kernel_locked"),
        "process_run" => ("core", "adapter_replaceable"),
        operation if operation.starts_with("state_") => ("state", "kernel_locked"),
        operation if operation.starts_with("trace_") => ("trace", "kernel_locked"),
        operation if operation.starts_with("log_") => ("logs", "kernel_locked"),
        operation if operation.starts_with("catalog_") => ("catalog_discovery", "kernel_locked"),
        operation if operation.starts_with("filesystem_") => ("filesystem", "adapter_replaceable"),
        operation if operation.starts_with("git_") => ("git", "adapter_replaceable"),
        operation if operation.starts_with("job_") => ("jobs", "adapter_replaceable"),
        operation if operation.starts_with("goal_") || operation.starts_with("question_") => {
            ("goals_questions", "record_plane")
        }
        operation if operation.starts_with("schedule_") => ("scheduler", "record_plane"),
        operation if operation.starts_with("context_control_") => {
            ("context_control", "record_plane")
        }
        operation
            if operation.starts_with("context_survivor_")
                || operation.starts_with("context_exclusion_")
                || operation == "context_policy_snapshot" =>
        {
            ("context_control", "record_plane")
        }
        operation if operation.starts_with("memory_") => ("memory", "record_plane"),
        operation if operation.starts_with("media_") => ("media", "record_plane"),
        operation if operation.starts_with("import_history_") => ("import_history", "record_plane"),
        operation if operation.starts_with("repository_tree_") => {
            ("repository_tree", "record_plane")
        }
        operation if operation.starts_with("import_preview_") => ("import_preview", "record_plane"),
        operation if operation.starts_with("program_execution_") => {
            ("program_execution", "record_plane")
        }
        operation if operation.starts_with("prompt_artifact_") => {
            ("prompt_artifacts", "record_plane")
        }
        operation if operation.starts_with("update_diagnostic_") => {
            ("update_diagnostics", "record_plane")
        }
        operation if operation.starts_with("device_") => ("device", "record_plane"),
        "notification_send" => ("notifications", "governance_locked"),
        operation if operation.starts_with("notification_") => ("notifications", "record_plane"),
        operation if operation.starts_with("procedural_") => ("procedural", "governance_locked"),
        operation if operation.starts_with("tool_source_") => ("tool_sources", "governance_locked"),
        operation if operation.starts_with("worker_package_") => {
            ("worker_packages", "governance_locked")
        }
        operation if operation.starts_with("subagent_task_") => ("subagents", "record_plane"),
        operation if operation.starts_with("subagent_") => ("subagents", "adapter_replaceable"),
        operation if operation.starts_with("module_program_execution_") => {
            ("module_program_execution", "module_owned")
        }
        "module_list" | "module_inspect" => ("module_registry", "governance_locked"),
        operation if operation.starts_with("module_proposal_") => {
            ("module_authoring", "governance_locked")
        }
        operation if operation.starts_with("module_validation_") => {
            ("module_validation", "governance_locked")
        }
        operation if operation.starts_with("module_install_") => {
            ("module_install", "governance_locked")
        }
        operation if operation.starts_with("module_dependency_") => {
            ("module_dependencies", "governance_locked")
        }
        operation if operation.starts_with("capability_binding_") => {
            ("capability_binding", "governance_locked")
        }
        operation if operation.starts_with("capability_shadow_trial_") => {
            ("capability_binding", "governance_locked")
        }
        operation if operation.starts_with("capability_replacement_") => {
            ("capability_binding", "governance_locked")
        }
        operation if operation.starts_with("capability_route_") => {
            ("capability_binding", "governance_locked")
        }
        operation if operation.starts_with("module_lifecycle_") => {
            ("module_lifecycle", "governance_locked")
        }
        operation if operation.starts_with("module_runtime_") => {
            ("module_runtime", "governance_locked")
        }
        operation if operation.starts_with("web_research_") => ("web_research", "record_plane"),
        operation if operation.starts_with("web_") => ("web", "adapter_replaceable"),
        _ => panic!("operation has no deterministic modularity classification: {operation}"),
    }
}

fn kernel_boundary_areas() -> Vec<KernelBoundaryArea> {
    vec![
        KernelBoundaryArea {
            area: "authority/grants",
            source: &[
                SourceRequirement {
                    path: "packages/agent/src/engine/authority/mod.rs",
                    markers: &[
                        "Grants are resolved",
                        "engine-owned store",
                        "provider clients",
                    ],
                },
                SourceRequirement {
                    path: "packages/agent/src/engine/mod.rs",
                    markers: &[
                        "engine-owned grant store before any handler runs",
                        "intent-shaped",
                    ],
                },
            ],
            locked_families: &[],
            locked_operations: &["observe"],
            allowed_classes: &["kernel_locked"],
        },
        KernelBoundaryArea {
            area: "event/session log",
            source: &[SourceRequirement {
                path: "packages/agent/src/domains/session/event_store/mod.rs",
                markers: &["transactional facade", "append-only", "deterministic"],
            }],
            locked_families: &["logs"],
            locked_operations: &[],
            allowed_classes: &["kernel_locked"],
        },
        KernelBoundaryArea {
            area: "resource store",
            source: &[
                SourceRequirement {
                    path: "packages/agent/src/engine/durability/mod.rs",
                    markers: &["Durable records", "source of truth", "Typed resource"],
                },
                SourceRequirement {
                    path: "packages/agent/src/engine/durability/resources/mod.rs",
                    markers: &[
                        "resource kernel",
                        "durable object model",
                        "projections over this store",
                    ],
                },
            ],
            locked_families: &[
                "goals_questions",
                "import_history",
                "import_preview",
                "media",
                "memory",
                "program_execution",
                "prompt_artifacts",
                "repository_tree",
                "scheduler",
                "update_diagnostics",
                "web_research",
            ],
            locked_operations: &[],
            allowed_classes: &["record_plane"],
        },
        KernelBoundaryArea {
            area: "redaction/provider-safety",
            source: &[
                SourceRequirement {
                    path: "packages/agent/src/shared/foundation/redaction.rs",
                    markers: &["redaction helpers", "credential shapes"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/session/event_store/redaction.rs",
                    markers: &["event payloads", "foundation redactor"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/capability/mod.rs",
                    markers: &["redacted", "bounded refs"],
                },
            ],
            locked_families: &[
                "trace",
                "catalog_discovery",
                "module_authoring",
                "module_validation",
            ],
            locked_operations: &["log_recent", "replay_manifest"],
            allowed_classes: &["kernel_locked", "governance_locked"],
        },
        KernelBoundaryArea {
            area: "trace/audit/replay/catalog",
            source: &[
                SourceRequirement {
                    path: "packages/agent/src/domains/capability/operations/mod.rs",
                    markers: &[
                        "trace evidence",
                        "OperationId::ReplayManifest",
                        "trace_bypassed",
                    ],
                },
                SourceRequirement {
                    path: "packages/agent/src/engine/durability/replay.rs",
                    markers: &["Replay read DTOs", "no replay executor"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/catalog_discovery/mod.rs",
                    markers: &[
                        "does not route",
                        "discovered capabilities",
                        "not invocation",
                    ],
                },
            ],
            locked_families: &["trace", "catalog_discovery"],
            locked_operations: &["replay_manifest"],
            allowed_classes: &["kernel_locked"],
        },
        KernelBoundaryArea {
            area: "transport boundary",
            source: &[
                SourceRequirement {
                    path: "packages/agent/src/transport/mod.rs",
                    markers: &[
                        "Thin client-facing",
                        "do not own domain behavior",
                        "must not implement",
                        "handler-shaped",
                    ],
                },
                SourceRequirement {
                    path: "packages/agent/src/transport/engine/mod.rs",
                    markers: &[
                        "Transport-neutral",
                        "caller-provided authority",
                        "runtime metadata",
                    ],
                },
                SourceRequirement {
                    path: "packages/agent/src/transport/http/auth.rs",
                    markers: &["bearer-token", "/engine/workers", "bearer token"],
                },
            ],
            locked_families: &[],
            locked_operations: &["observe"],
            allowed_classes: &["kernel_locked"],
        },
        KernelBoundaryArea {
            area: "module governance pipeline",
            source: &[
                SourceRequirement {
                    path: "packages/agent/src/domains/module_registry/mod.rs",
                    markers: &["not module activation", "must never install"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/module_authoring/mod.rs",
                    markers: &["proposals", "installed modules", "non-executable"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/module_validation/mod.rs",
                    markers: &["validation reports", "metadata only"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/module_install/mod.rs",
                    markers: &["install candidates", "metadata gate", "execute module code"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/module_dependencies/mod.rs",
                    markers: &["policy activation", "metadata only", "downloads"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/capability_binding/mod.rs",
                    markers: &[
                        "Capability binding policy, shadow-trial custody, and scoped route control",
                        "governed route records",
                        "kernel_locked",
                    ],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/module_lifecycle/mod.rs",
                    markers: &["lifecycle", "metadata state", "execute module code"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/module_runtime/mod.rs",
                    markers: &["runtime supervision", "metadata gate", "PTYs/browsers"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/tool_sources/mod.rs",
                    markers: &["not activation", "MCP servers", "register catalog"],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/worker_lifecycle/mod.rs",
                    markers: &["launch policy", "worker protocol", "bypass scoped tokens"],
                },
            ],
            locked_families: &[
                "capability_binding",
                "module_authoring",
                "module_dependencies",
                "module_install",
                "module_lifecycle",
                "module_registry",
                "module_runtime",
                "module_validation",
                "procedural",
                "tool_sources",
                "worker_packages",
            ],
            locked_operations: &["notification_send"],
            allowed_classes: &["governance_locked"],
        },
    ]
}

fn adapter_seam_areas() -> Vec<AdapterSeamArea> {
    vec![
        AdapterSeamArea {
            family: "filesystem",
            operations: &[],
            source: &[SourceRequirement {
                path: "packages/agent/src/domains/filesystem/mod.rs",
                markers: &[
                    "exact-root authority",
                    "preview/commit parity",
                    "provider-safe refs",
                    "replay/idempotency evidence",
                    "rollback/disable metadata",
                ],
            }],
            inventory_markers: &[
                "authority",
                "preview_commit_evidence",
                "provider_safe_refs",
                "replay_idempotency",
                "rollback_disable_refs",
            ],
            docs_markers: &[
                "exact root authority",
                "preview/commit evidence",
                "bounded file side effects",
            ],
            record_plane_strategy: false,
        },
        AdapterSeamArea {
            family: "git",
            operations: &[],
            source: &[SourceRequirement {
                path: "packages/agent/src/domains/git/mod.rs",
                markers: &[
                    "exact repository authority",
                    "HEAD/index parity",
                    "provider-safe refs",
                    "replay/idempotency evidence",
                    "rollback/disable metadata",
                ],
            }],
            inventory_markers: &[
                "authority",
                "head_index_evidence",
                "provider_safe_refs",
                "replay_idempotency",
                "rollback_disable_refs",
            ],
            docs_markers: &[
                "exact repository authority",
                "HEAD/index evidence",
                "guarded Git side effects",
            ],
            record_plane_strategy: false,
        },
        AdapterSeamArea {
            family: "core",
            operations: &["process_run"],
            source: &[SourceRequirement {
                path: "packages/agent/src/domains/capability/operations/process.rs",
                markers: &[
                    "trusted working-directory authority",
                    "networkPolicy: none",
                    "bounded output",
                    "provider-safe result projection",
                    "rollback/disable metadata",
                ],
            }],
            inventory_markers: &[
                "authority",
                "network_none",
                "bounded_output",
                "replay_idempotency",
                "rollback_disable_refs",
            ],
            docs_markers: &[
                "trusted working-directory authority",
                "networkPolicy none",
                "bounded process side effects",
            ],
            record_plane_strategy: false,
        },
        AdapterSeamArea {
            family: "jobs",
            operations: &[],
            source: &[SourceRequirement {
                path: "packages/agent/src/domains/jobs/mod.rs",
                markers: &[
                    "supervised-runtime",
                    "durable lifecycle parity",
                    "provider-safe refs",
                    "bounded side effects",
                    "rollback/disable metadata",
                ],
            }],
            inventory_markers: &[
                "authority",
                "lifecycle_evidence",
                "provider_safe_refs",
                "replay_idempotency",
                "rollback_disable_refs",
            ],
            docs_markers: &[
                "supervised runtime authority",
                "lifecycle evidence",
                "bounded job side effects",
            ],
            record_plane_strategy: false,
        },
        AdapterSeamArea {
            family: "web",
            operations: &[],
            source: &[SourceRequirement {
                path: "packages/agent/src/domains/web/mod.rs",
                markers: &[
                    "exact network authority",
                    "robots/source parity",
                    "provider-safe refs",
                    "fail-closed side effects",
                    "rollback/disable metadata",
                ],
            }],
            inventory_markers: &[
                "authority",
                "robots_source_evidence",
                "provider_safe_refs",
                "replay_idempotency",
                "rollback_disable_refs",
            ],
            docs_markers: &[
                "exact network authority",
                "robots/source evidence",
                "fail-closed side effects",
            ],
            record_plane_strategy: false,
        },
        AdapterSeamArea {
            family: "subagents",
            operations: &[
                "subagent_launch",
                "subagent_status",
                "subagent_result",
                "subagent_cancel",
            ],
            source: &[SourceRequirement {
                path: "packages/agent/src/domains/subagents/mod.rs",
                markers: &[
                    "exact task/runtime/job",
                    "reviewable merge-proposal parity",
                    "provider-safe refs",
                    "bounded side effects",
                    "rollback/disable metadata",
                ],
            }],
            inventory_markers: &[
                "authority",
                "merge_evidence",
                "provider_safe_refs",
                "replay_idempotency",
                "rollback_disable_refs",
            ],
            docs_markers: &[
                "exact task/runtime/job authority",
                "merge evidence",
                "bounded subagent side effects",
            ],
            record_plane_strategy: false,
        },
        AdapterSeamArea {
            family: "context_control",
            operations: &["context_control_compact"],
            source: &[
                SourceRequirement {
                    path: "packages/agent/src/domains/context_control/mod.rs",
                    markers: &[
                        "summarizer strategy only",
                        "server-owned",
                        "provider-safe",
                        "survivor/exclusion policy records",
                        "rollback/disable metadata",
                    ],
                },
                SourceRequirement {
                    path: "packages/agent/src/domains/agent/context/mod.rs",
                    markers: &["summarizer implementation", "record-plane custody"],
                },
            ],
            inventory_markers: &[
                "summarizer_seam",
                "provider_safe_summary",
                "context_audit_records",
                "replay_idempotency",
                "rollback_disable_refs",
            ],
            docs_markers: &[
                "summarizer strategy",
                "context audit records",
                "provider-safe summary",
            ],
            record_plane_strategy: true,
        },
    ]
}

#[test]
fn capability_modularity_artifacts_are_linked_and_described() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let readme = read_repo_file(README_PATH);

    for required in [
        "# Capability Modularity Scorecard",
        "Current score:",
        "Source of truth: `packages/agent/src/domains/capability/operations/operation_contract/mod.rs`",
        "Provider-visible surface: one tool, `capability::execute`",
        "| CMS-0 | Registry/dispatch baseline |",
        "| CMS-8 | Docs and static gates |",
        "Kernel Boundary Lockdown Evidence",
        "Binding Policy Evidence",
        "Adapter Seam Hardening Evidence",
        "Shadow Replacement Trial Evidence",
        "accepted-shadow-projection replay seam",
        "without returning a built-in success",
        "active route state",
        "Follow-on Slices",
    ] {
        assert!(
            scorecard.contains(required),
            "scorecard missing required text: {required}"
        );
    }

    assert!(
        !scorecard.contains("does not yet invoke a live module-owned adapter projection"),
        "capability modularity scorecard must not describe the completed route projection milestone as missing"
    );
    for forbidden in [
        "live module-adapter replacement execution is tracked by the dynamic replacement scorecard and remains intentionally deferred",
        "live module-adapter execution remains deferred",
        "they do not add package installation, dependency restoration, network behavior, production deployment, or live module-adapter execution",
    ] {
        assert!(
            !scorecard.contains(forbidden),
            "capability modularity scorecard must not retain stale route-projection deferral text: {forbidden}"
        );
    }
    for class in OWNERSHIP_CLASSES {
        assert!(
            scorecard.contains(class),
            "scorecard must define ownership class {class}"
        );
    }

    for required in [
        "Registry count",
        "Dispatch parity",
        "Machine inventory",
        "Kernel boundary lockdown",
        "Capability binding policy",
        "Adapter seam hardening",
        "Shadow replacement trial",
        "Governed route records",
        "acceptedProjectionReplayed: true",
        "routeExecutionMode: supervised_shadow_projection_replay",
        "liveModuleCodeExecutionSupported: false",
        "builtInProjectionUsed: false",
        "Future operations must update the TSV, this scorecard, and this manifest",
    ] {
        assert!(
            evidence.contains(required),
            "evidence manifest missing required text: {required}"
        );
    }
    for forbidden in [
        "annotates built-in provider-safe projections; live module-adapter projection execution remains deferred",
        "annotates the built-in provider-safe projection with route evidence",
        "It does not mutate the dispatch table, invoke a live module adapter projection",
        "route event/projection fields set `moduleAdapterInvoked: false`",
        "no runtime capability routing",
    ] {
        assert!(
            !evidence.contains(forbidden),
            "evidence manifest must not retain stale metadata-only routing text: {forbidden}"
        );
    }

    for required in [SCORECARD_PATH, INVENTORY_PATH, EVIDENCE_PATH] {
        assert!(
            readme.contains(required),
            "README must link capability modularity artifact {required}"
        );
    }
    for required in [
        "kernel_locked",
        "governance_locked",
        "Kernel Boundary Lockdown",
        "Capability Binding Policy",
        "capability_binding",
        "adapter_replaceable",
        "module_owned",
        "capability_modularity_scorecard_invariants",
    ] {
        assert!(
            readme.contains(required),
            "README missing capability modularity invariant text: {required}"
        );
    }
}

#[test]
fn capability_modularity_inventory_matches_deterministic_prefix_policy() {
    for row in parse_inventory() {
        let (expected_family, expected_class) = expected_family_and_class(&row.operation);
        assert_eq!(
            row.family, expected_family,
            "{} family drifted; update prefix policy and evidence intentionally",
            row.operation
        );
        assert_eq!(
            row.ownership_class, expected_class,
            "{} ownership class drifted; update prefix policy and evidence intentionally",
            row.operation
        );
    }
}

#[test]
fn capability_modularity_inventory_covers_execute_registry_once() {
    let registry_operations = registry_operations();
    let rows = parse_inventory();
    let inventory_operations: Vec<_> = rows.iter().map(|row| row.operation.clone()).collect();

    assert_eq!(
        registry_operations.len(),
        EXPECTED_OPERATION_COUNT,
        "verified baseline operation count changed; update the scorecard intentionally"
    );
    assert_eq!(
        rows.len(),
        EXPECTED_OPERATION_COUNT,
        "inventory must classify every current operation exactly once"
    );
    assert_eq!(
        duplicate_values(&registry_operations),
        Vec::<String>::new(),
        "registry has duplicate operation names"
    );
    assert_eq!(
        duplicate_values(&inventory_operations),
        Vec::<String>::new(),
        "inventory has duplicate operation rows"
    );

    let registry_set: BTreeSet<_> = registry_operations.iter().cloned().collect();
    let inventory_set: BTreeSet<_> = inventory_operations.into_iter().collect();
    let missing: Vec<_> = registry_set.difference(&inventory_set).cloned().collect();
    let extra: Vec<_> = inventory_set.difference(&registry_set).cloned().collect();
    assert!(
        missing.is_empty(),
        "inventory missing operations: {missing:?}"
    );
    assert!(
        extra.is_empty(),
        "inventory has unknown operations: {extra:?}"
    );
}

#[test]
fn capability_modularity_dispatch_registry_parity_is_static() {
    let registry_operations = registry_operations();
    let dispatch_operations = dispatch_operations();

    assert_eq!(
        dispatch_operations.len(),
        EXPECTED_OPERATION_COUNT,
        "dispatch arm count changed; update registry and scorecard together"
    );
    assert_eq!(
        duplicate_values(&dispatch_operations),
        Vec::<String>::new(),
        "dispatch has duplicate operation arms"
    );

    let registry_set: BTreeSet<_> = registry_operations.into_iter().collect();
    let dispatch_set: BTreeSet<_> = dispatch_operations.into_iter().collect();
    let missing_dispatch: Vec<_> = registry_set.difference(&dispatch_set).cloned().collect();
    let extra_dispatch: Vec<_> = dispatch_set.difference(&registry_set).cloned().collect();
    assert!(
        missing_dispatch.is_empty(),
        "registry operations missing dispatch arms: {missing_dispatch:?}"
    );
    assert!(
        extra_dispatch.is_empty(),
        "dispatch arms missing registry entries: {extra_dispatch:?}"
    );
}

#[test]
fn capability_modularity_rows_have_valid_classes_scores_and_actions() {
    let allowed_classes: BTreeSet<_> = OWNERSHIP_CLASSES.into_iter().collect();
    let allowed_actions: BTreeSet<_> = NEXT_ACTIONS.into_iter().collect();

    for row in parse_inventory() {
        assert!(
            !row.family.trim().is_empty(),
            "family must be set for {}",
            row.operation
        );
        assert!(
            !row.current_owner.trim().is_empty(),
            "currentOwner must be set for {}",
            row.operation
        );
        assert!(
            !row.replacement_target.trim().is_empty(),
            "replacementTarget must be set for {}",
            row.operation
        );
        assert!(
            allowed_classes.contains(row.ownership_class.as_str()),
            "invalid ownershipClass for {}: {}",
            row.operation,
            row.ownership_class
        );
        assert!(
            allowed_actions.contains(row.next_action.as_str()),
            "invalid nextAction for {}: {}",
            row.operation,
            row.next_action
        );
    }
}

#[test]
fn capability_modularity_kernel_and_governance_rows_are_not_replaceable() {
    for row in parse_inventory() {
        if row.ownership_class != "kernel_locked" && row.ownership_class != "governance_locked" {
            continue;
        }
        assert_eq!(
            row.scores["bindingScore"], 0,
            "{} is {} and must not expose a binding seam",
            row.operation, row.ownership_class
        );
        assert_eq!(
            row.scores["rollbackScore"], 0,
            "{} is {} and must not expose replacement rollback",
            row.operation, row.ownership_class
        );
        assert!(
            !row.replacement_target.contains("replace"),
            "{} is {} but replacementTarget implies replacement: {}",
            row.operation,
            row.ownership_class,
            row.replacement_target
        );
    }
}

#[test]
fn capability_modularity_kernel_boundary_lockdown_is_source_backed() {
    let rows = parse_inventory();
    let row_by_operation: BTreeMap<_, _> = rows
        .iter()
        .map(|row| (row.operation.as_str(), row))
        .collect();
    let evidence = read_repo_file(EVIDENCE_PATH);
    let scorecard = read_repo_file(SCORECARD_PATH);

    for area in kernel_boundary_areas() {
        assert!(
            evidence.contains(area.area),
            "evidence manifest must record kernel-boundary area {}",
            area.area
        );
        assert!(
            scorecard.contains(area.area),
            "scorecard must record kernel-boundary area {}",
            area.area
        );

        for source in area.source {
            assert!(
                evidence.contains(source.path),
                "evidence manifest must cite {} for {}",
                source.path,
                area.area
            );
            let source_text = read_repo_file(source.path);
            for marker in source.markers {
                assert!(
                    source_text.contains(marker),
                    "{} source marker drifted in {}: {marker}",
                    area.area,
                    source.path
                );
            }
        }

        let allowed_classes: BTreeSet<_> = area.allowed_classes.iter().copied().collect();
        for row in rows.iter().filter(|row| {
            area.locked_families.contains(&row.family.as_str())
                || area.locked_operations.contains(&row.operation.as_str())
        }) {
            assert!(
                allowed_classes.contains(row.ownership_class.as_str()),
                "{} belongs to the {} boundary and must not move to {} without updating the scorecard, binding policy, and boundary evidence",
                row.operation,
                area.area,
                row.ownership_class
            );
            assert!(
                row.ownership_class != "adapter_replaceable"
                    && row.ownership_class != "module_owned",
                "{} belongs to the {} boundary and must not be adapter/module-routed",
                row.operation,
                area.area
            );
            assert!(
                row.scores["providerSafetyScore"] >= 3,
                "{} belongs to the {} boundary and must retain provider-safe projections",
                row.operation,
                area.area
            );
        }

        for operation in area.locked_operations {
            assert!(
                row_by_operation.contains_key(operation),
                "{} boundary references unknown operation {operation}",
                area.area
            );
        }
    }
}

#[test]
fn capability_modularity_adapter_seams_are_source_backed_and_measurable() {
    let rows = parse_inventory();
    let row_by_operation: BTreeMap<_, _> = rows
        .iter()
        .map(|row| (row.operation.as_str(), row))
        .collect();
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let mut covered_adapter_operations = BTreeSet::new();

    for area in adapter_seam_areas() {
        for source in area.source {
            assert!(
                evidence.contains(source.path),
                "evidence manifest must cite {} for {} adapter seam",
                source.path,
                area.family
            );
            let source_text = read_repo_file(source.path);
            for marker in source.markers {
                assert!(
                    source_text.contains(marker),
                    "{} adapter seam source marker drifted in {}: {marker}",
                    area.family,
                    source.path
                );
            }
        }

        for marker in area.docs_markers {
            assert!(
                scorecard.contains(marker),
                "scorecard must name {marker} for {} adapter seam",
                area.family
            );
            assert!(
                evidence.contains(marker),
                "evidence manifest must name {marker} for {} adapter seam",
                area.family
            );
        }

        let seam_rows: Vec<&InventoryRow> = if area.operations.is_empty() {
            rows.iter()
                .filter(|row| {
                    row.family == area.family && row.ownership_class == "adapter_replaceable"
                })
                .collect()
        } else {
            area.operations
                .iter()
                .map(|operation| {
                    *row_by_operation.get(operation).unwrap_or_else(|| {
                        panic!(
                            "{} seam references unknown operation {operation}",
                            area.family
                        )
                    })
                })
                .collect()
        };
        assert!(
            !seam_rows.is_empty(),
            "{} seam must cover at least one operation",
            area.family
        );

        for row in seam_rows {
            if area.record_plane_strategy {
                assert_eq!(
                    row.ownership_class, "record_plane",
                    "{} strategy seam must keep record custody server-owned",
                    row.operation
                );
                assert!(
                    row.replacement_target.contains("context_audit_records"),
                    "{} compaction strategy seam must preserve context audit records",
                    row.operation
                );
                assert!(
                    row.scores["bindingScore"] >= 1,
                    "{} strategy seam must name binding prerequisites",
                    row.operation
                );
            } else {
                assert_eq!(
                    row.ownership_class, "adapter_replaceable",
                    "{} must stay adapter_replaceable for seam hardening",
                    row.operation
                );
                covered_adapter_operations.insert(row.operation.as_str());
                assert!(
                    row.scores["bindingScore"] >= 2,
                    "{} adapter seam must be backed by binding-policy metadata",
                    row.operation
                );
            }

            for marker in area.inventory_markers {
                assert!(
                    row.replacement_target.contains(marker),
                    "{} replacementTarget must name {marker}: {}",
                    row.operation,
                    row.replacement_target
                );
            }
            assert!(
                row.scores["providerSafetyScore"] >= 3,
                "{} seam must retain provider-safe projection evidence",
                row.operation
            );
            assert!(
                row.scores["replayScore"] >= 2,
                "{} seam must retain replay/idempotency evidence",
                row.operation
            );
            assert!(
                row.scores["rollbackScore"] >= 1,
                "{} seam must name rollback/disable prerequisites",
                row.operation
            );
            assert!(
                row.scores["testScore"] >= 3,
                "{} seam must be locked by focused tests",
                row.operation
            );
            assert_eq!(
                row.next_action, "shadow_trial",
                "{} seam hardening should hand off to the shadow trial",
                row.operation
            );
        }
    }

    let adapter_operations: BTreeSet<_> = rows
        .iter()
        .filter(|row| row.ownership_class == "adapter_replaceable")
        .map(|row| row.operation.as_str())
        .collect();
    let uncovered: Vec<_> = adapter_operations
        .difference(&covered_adapter_operations)
        .copied()
        .collect();
    assert!(
        uncovered.is_empty(),
        "adapter_replaceable operations missing seam coverage: {uncovered:?}"
    );
}

#[test]
fn capability_modularity_replaceable_and_module_owned_rows_name_controls() {
    for row in parse_inventory() {
        match row.ownership_class.as_str() {
            "adapter_replaceable" => {
                assert!(
                    row.scores["bindingScore"] >= 1,
                    "{} is adapter_replaceable but lacks a documented binding seam",
                    row.operation
                );
                assert!(
                    row.next_action == "shadow_trial",
                    "{} is adapter_replaceable and must hand off to shadow-trial follow-up",
                    row.operation
                );
                assert!(
                    row.replacement_target.contains("policy")
                        || row.replacement_target.contains("evidence")
                        || row.replacement_target.contains("authority"),
                    "{} is adapter_replaceable but does not name a policy/evidence/authority constraint",
                    row.operation
                );
            }
            "module_owned" => {
                assert!(
                    row.scores["bindingScore"] >= 2,
                    "{} is module_owned but lacks a concrete binding score",
                    row.operation
                );
                assert!(
                    row.scores["rollbackScore"] >= 2,
                    "{} is module_owned but lacks rollback visibility",
                    row.operation
                );
                assert!(
                    row.replacement_target.contains("supervised"),
                    "{} is module_owned and must name supervised replacement constraints",
                    row.operation
                );
            }
            "record_plane" => {
                assert!(
                    row.replacement_target.contains("record")
                        || row.replacement_target.contains("custody")
                        || row.replacement_target.contains("policy"),
                    "{} is record_plane but does not name record custody or policy constraints",
                    row.operation
                );
            }
            "deferred" => panic!(
                "{} is deferred; the baseline must not hide unclassified operations",
                row.operation
            ),
            _ => {}
        }
    }
}
