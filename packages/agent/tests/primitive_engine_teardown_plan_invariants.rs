//! Static gates for the primitive engine teardown planning scorecard.

use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

fn assert_repo_path_absent(path: &str, label: &str) {
    let full_path = repo_path(path);
    assert!(
        !full_path.exists(),
        "{label} must be physically deleted from the primitive branch: {}",
        full_path.display()
    );
}

fn assert_absent(haystack: &str, banned: &[&str], label: &str) {
    for needle in banned {
        assert!(
            !haystack.contains(needle),
            "{label} must not retain primitive-teardown-banned text `{needle}`"
        );
    }
}

fn read_repo_source_trees(paths: &[&str]) -> String {
    fn append_file(output: &mut String, path: &Path) {
        if !matches!(
            path.extension().and_then(|extension| extension.to_str()),
            Some("rs" | "swift" | "yml" | "yaml")
        ) {
            return;
        }
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name == "SourceGuardTests.swift")
        {
            return;
        }
        let text = std::fs::read_to_string(path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
        output.push_str("\n// FILE: ");
        output.push_str(&path.display().to_string());
        output.push('\n');
        output.push_str(&text);
    }

    fn append_path(output: &mut String, path: &Path) {
        if path.is_file() {
            append_file(output, path);
            return;
        }
        let entries = std::fs::read_dir(path)
            .unwrap_or_else(|error| panic!("failed to enumerate {}: {error}", path.display()));
        for entry in entries {
            let entry = entry.expect("directory entry should be readable");
            let path = entry.path();
            if path.is_dir() {
                append_path(output, &path);
            } else {
                append_file(output, &path);
            }
        }
    }

    let mut output = String::new();
    for path in paths {
        append_path(&mut output, &repo_path(path));
    }
    output
}

#[test]
fn primitive_engine_teardown_plan_stays_formalized() {
    let scorecard = read_repo_file("packages/agent/docs/primitive-engine-teardown-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/primitive-engine-teardown-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# Primitive Engine Teardown Scorecard",
        "Current score: **100/100**",
        "Status: **completed**",
        "Branch: `codex/primitive-engine-teardown`",
        "There are no users and no compatibility obligations.",
        "No backward compatibility",
        "the model receives one initial tool, `execute`",
        "No runtime approval prompt plane",
        "No invisible agent authorship",
        "First-Class Traceability Primitive",
        "The soul is not a toolbox, recipe pack, policy profile, or product guide.",
        "Target Bare Loop",
        "Agent Soul Seed",
        "| PET-0 | Branch, baseline, and plan formalization | 5 | passed_after_fix |",
        "| PET-1 | Primitive taxonomy and deletion inventory | 8 | passed_after_fix |",
        "| PET-2 | Server domain registration teardown | 12 | passed_after_fix |",
        "| PET-3 | Single execute primitive | 12 | passed_after_fix |",
        "| PET-4 | Soul and agent-owned state workspace | 10 | passed_after_fix |",
        "| PET-5 | Session, event, ledger, and resource collapse | 8 | passed_after_fix |",
        "| PET-6 | Rules, skills, hooks, guardrails, approvals, and policy deletion | 8 | passed_after_fix |",
        "| PET-7 | Self-authored worker/capability substrate | 8 | passed_after_fix |",
        "| PET-8 | iOS primitive shell | 10 | passed_after_fix |",
        "| PET-9 | Documentation and managed asset rewrite | 5 | passed_after_fix |",
        "| PET-10 | Absence gates, traceability gates, and dead-code cleanup | 6 | passed_after_fix |",
        "| PET-11 | End-to-end closeout and \"cannot remove more\" audit | 8 | passed_after_fix |",
        "Total weight: **100**",
        "`provider_surface_exports_only_execute`",
        "`deleted_first_party_capabilities_are_absent`",
        "`context_has_soul_not_rules_or_skills`",
        "`ios_primary_shell_has_no_fixed_product_modes`",
        "`no_legacy_fallback_compatibility_paths`",
        "`agent_trace_records_are_first_class`",
        "`prompt_media_uses_unified_attachment_primitive`",
        "`primitive_loop_end_to_end`",
        "After PET-11 passes, create a separate self-adapting-agent scorecard",
    ] {
        assert!(
            scorecard.contains(required),
            "primitive teardown scorecard missing required text: {required}"
        );
    }

    for required in [
        "# Primitive Engine Teardown Evidence Manifest",
        "Current score: **100/100**",
        "Status: **completed**",
        "New teardown branch: `codex/primitive-engine-teardown`",
        "Compatibility assumption: none.",
        "| PET-0 | passed_after_fix |",
        "| PET-1 | passed_after_fix |",
        "| PET-2 | passed_after_fix |",
        "| PET-3 | passed_after_fix |",
        "| PET-4 | passed_after_fix |",
        "| PET-5 | passed_after_fix |",
        "| PET-6 | passed_after_fix |",
        "| PET-7 | passed_after_fix |",
        "| PET-8 | passed_after_fix |",
        "| PET-9 | passed_after_fix |",
        "| PET-10 | passed_after_fix |",
        "| PET-11 | passed_after_fix |",
        "PET-11 Final Primitive Loop Closeout Addendum",
        "Provider and primitive-loop fixture proof",
        "Database and trace proof from the same fresh run",
        "iOS closeout screenshots",
        "Final retained-surface scans",
    ] {
        assert!(
            manifest.contains(required),
            "primitive teardown evidence manifest missing required text: {required}"
        );
    }

    assert!(
        readme.contains("packages/agent/docs/primitive-engine-teardown-scorecard.md")
            && readme.contains("completed")
            && readme.contains("clean-break primitive engine teardown scorecard")
            && readme
                .contains("packages/agent/docs/primitive-engine-teardown-evidence-manifest.md"),
        "README living-doc map must link the completed primitive teardown scorecard and evidence manifest"
    );
}

#[test]
fn primitive_engine_teardown_inventory_stays_exhaustive() {
    let inventory = read_repo_file("packages/agent/docs/primitive-engine-teardown-inventory.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# Primitive Engine Teardown Inventory",
        "PET-1 status: `passed_after_fix`",
        "Classification vocabulary: `retain`, `delete`, `successor`.",
        "Source Audit Commands",
        "Rust Domain Inventory",
        "Engine Primitive Worker Inventory",
        "Runner Context Plane Inventory",
        "First-Party Managed Skill Inventory",
        "Documentation Inventory",
        "iOS Top-Level Source Inventory",
        "iOS Primary View Inventory",
        "Settings Surface Inventory",
        "Deletion Checkpoint Order",
    ] {
        assert!(
            inventory.contains(required),
            "primitive teardown inventory missing required text: {required}"
        );
    }

    for domain in [
        "agent",
        "auth",
        "blob",
        "browser",
        "capability",
        "capability_support",
        "context",
        "cron",
        "device",
        "display",
        "events",
        "filesystem",
        "git",
        "import",
        "job",
        "logs",
        "mcp",
        "memory",
        "message",
        "model",
        "notifications",
        "plan",
        "process",
        "program",
        "prompt_library",
        "repo",
        "sandbox",
        "self_extension",
        "session",
        "settings",
        "skills",
        "system",
        "transcription",
        "tree",
        "voice_notes",
        "web",
        "worktree",
    ] {
        assert!(
            inventory.contains(&format!("| `{domain}` |")),
            "primitive teardown inventory missing Rust domain row for {domain}"
        );
    }

    for worker in [
        "stream",
        "state",
        "queue",
        "resource",
        "trigger",
        "grant",
        "approval",
        "catalog",
        "control",
        "worker",
        "observability",
        "storage",
        "ui",
        "module",
    ] {
        assert!(
            inventory.contains(&format!("| `{worker}` |")),
            "primitive teardown inventory missing primitive worker row for {worker}"
        );
    }

    for skill in [
        "browse-the-web",
        "explore",
        "find-skill",
        "generate",
        "git-sync",
        "google-workspace",
        "heal-skill",
        "humanizer",
        "knowledge",
        "manage-automations",
        "old-english",
        "plan",
        "publish-website",
        "sandbox",
        "self-deploy",
        "self-extend",
        "self-inspect",
        "twitter",
        "vault",
    ] {
        assert!(
            inventory.contains(&format!("| `{skill}` |")),
            "primitive teardown inventory missing managed skill row for {skill}"
        );
    }

    for view in [
        "AgentControl",
        "Attachments",
        "AuditDetails",
        "Capabilities",
        "Chat",
        "Components",
        "EngineApproval",
        "InputBar",
        "MessageBubble",
        "Notifications",
        "Onboarding",
        "Process",
        "PromptLibrary",
        "Session",
        "SessionTree",
        "Settings",
        "Skills",
        "SourceChanges",
        "Subagents",
        "System",
        "UserInteraction",
        "VoiceNotes",
        "Work",
    ] {
        assert!(
            inventory.contains(&format!("| `{view}` |")),
            "primitive teardown inventory missing iOS view row for {view}"
        );
    }

    assert!(
        readme.contains("packages/agent/docs/primitive-engine-teardown-inventory.md"),
        "README living-doc map must link the PET-1 primitive teardown inventory"
    );
}

#[test]
fn context_has_soul_and_agent_state_not_rules_skills_hooks_or_policy_planes() {
    let messages = read_repo_file("packages/agent/src/shared/protocol/messages.rs");
    assert!(
        messages.contains("pub agent_state_context: Option<String>"),
        "provider Context must expose agent-owned state as the only durable behavior context"
    );
    assert_absent(
        &messages,
        &[
            "rules_content",
            "memory_content",
            "skill_index_context",
            "skill_activation_context",
            "skill_context",
            "skill_removal_context",
            "job_results_context",
            "dynamic_rules_context",
            "capability_primer_context",
            "hook_context",
        ],
        "provider Context",
    );

    let composition =
        read_repo_file("packages/agent/src/domains/model/providers/shared/context_composition.rs");
    assert!(
        composition.contains("\"agent.soul\"")
            && composition.contains("\"agent.state\"")
            && composition.contains("Agent State"),
        "provider context composition must be soul plus agent-owned state"
    );
    assert_absent(
        &composition,
        &[
            "project.rules",
            "memory.root",
            "dynamic.rules",
            "capabilities.primer",
            "skills.",
            "jobs.results",
            "hooks.addContext",
            "Worker Guide",
            "Project Rules",
            "Active Rules",
            "Skill Index",
            "Hook Context",
        ],
        "provider context composition",
    );

    let home_and_runner_context = [
        read_repo_file("packages/agent/src/shared/foundation/constitution.rs"),
        read_repo_file("packages/agent/src/domains/model/providers/anthropic/message_converter.rs"),
        read_repo_file("packages/agent/src/domains/agent/runner/agent/turn_runner.rs"),
        read_repo_file("packages/agent/src/domains/agent/runner/profile_runtime.rs"),
    ]
    .join("\n");
    assert_absent(
        &home_and_runner_context,
        &[
            "Project rules, memory snapshot, skill index",
            "Dynamic rules, active skill bodies, job results",
            "compiled by profile context policy",
            "rules, system prompt",
            "system prompt, rules",
            "Volatile parts (memory",
            "messages, rules, and token tracking",
            "prompt/policy `.md` files",
        ],
        "home/profile/provider context comments",
    );

    let soul = read_repo_file("packages/agent/src/domains/agent/runner/context/soul.rs");
    assert!(
        soul.contains("pub const AGENT_SOUL")
            && soul.contains("learn from the environment")
            && soul.contains("agent-owned state")
            && soul.contains("one capability: `execute`"),
        "agent soul seed must be a small audited primitive instruction"
    );
    assert_absent(
        &soul,
        &[
            "toolbox",
            "recipe pack",
            "worker guide",
            "Available Skills",
            "AGENTS.md",
            "CLAUDE.md",
            "hook",
            "guardrail",
        ],
        "agent soul seed",
    );

    let run_context = read_repo_file("packages/agent/src/domains/agent/runner/types.rs");
    assert_absent(
        &run_context,
        &[
            "skill_index_context",
            "skill_activation_context",
            "skill_context",
            "skill_removal_context",
            "job_results",
            "dynamic_rules_context",
            "capability_primer_context",
            "hook_context",
            "subagent_depth",
            "subagent_max_depth",
        ],
        "RunContext",
    );

    let execute = read_repo_file("packages/agent/src/domains/agent/runtime/service/execute.rs");
    assert!(
        execute.contains("load_agent_state_context"),
        "prompt runtime must load agent-owned state through the primitive state namespace"
    );
    assert_absent(
        &execute,
        &[
            "build_prompt_hooks",
            "apply_user_prompt_submit_hook",
            "fire_session_start_hook",
            "fire_worktree_acquired_hook",
            "prepare_skill_context_from_session",
            "collect_pending_skill_payloads",
            "build_skill_index_context",
            "skill_registry",
            "hook_abort_tracker",
            "job_manager",
            "subagent_manager",
            "guardrails",
        ],
        "prompt runtime execute path",
    );

    let agent_build =
        read_repo_file("packages/agent/src/domains/agent/runtime/service/agent_build.rs");
    assert_absent(
        &agent_build,
        &[
            "GuardrailEngine",
            "guardrails",
            "HookEngine",
            "hooks",
            "subagent_manager",
            "job_manager",
            "rules_content",
            "memory_content",
            "rules_index",
            "pre_activated_rules",
            "load_system_prompt_from_file",
            "load_global_system_prompt",
            "context_policy",
            "capability_execution_policy",
            "primitive_surface_policy",
            "denied_primitives",
        ],
        "prompt agent builder",
    );
}

#[test]
fn prompt_loop_internals_have_no_hidden_policy_or_worker_planes() {
    for (label, path) in [
        (
            "agent factory",
            "packages/agent/src/domains/agent/runner/orchestrator/agent_factory.rs",
        ),
        (
            "tron agent",
            "packages/agent/src/domains/agent/runner/agent/tron_agent.rs",
        ),
        (
            "turn runner",
            "packages/agent/src/domains/agent/runner/agent/turn_runner.rs",
        ),
        (
            "capability phase",
            "packages/agent/src/domains/agent/runner/agent/turn_runner/capability_invocations.rs",
        ),
        (
            "capability executor",
            "packages/agent/src/domains/agent/runner/agent/capability_invocation_executor.rs",
        ),
        (
            "compaction handler",
            "packages/agent/src/domains/agent/runner/agent/compaction_handler.rs",
        ),
        (
            "context manager",
            "packages/agent/src/domains/agent/runner/context/context_manager.rs",
        ),
        (
            "context manager types",
            "packages/agent/src/domains/agent/runner/context/types.rs",
        ),
        (
            "primitive surface resolver",
            "packages/agent/src/domains/agent/runner/agent/primitive_surface.rs",
        ),
    ] {
        if !repo_path(path).exists() {
            continue;
        }
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "GuardrailEngine",
                "guardrail",
                "HookEngine",
                "hook",
                "subagent",
                "job_manager",
                "process_manager",
                "output_buffer_registry",
                "ContextPolicy",
                "context_policy",
                "PrimitiveSurfacePolicy",
                "primitive_surface_policy",
                "CapabilityExecutionPolicy",
                "capability_execution_policy",
                "denied_primitives",
                "is_unattended",
                "rules_content",
                "dynamic_rules",
                "RulesTracker",
                "rules_tracker",
                "RulesIndex",
                "memory_content",
                "session_memories",
                "skill",
                "approval",
                "selectedTarget",
                "bindingDecision",
            ],
            label,
        );
    }
}

#[test]
fn server_capability_identity_stays_primitive_only() {
    let identity_paths = [
        (
            "capability event identity dto",
            "packages/agent/src/shared/protocol/events/capability.rs",
        ),
        (
            "capability invocation executor",
            "packages/agent/src/domains/agent/runner/agent/capability_invocation_executor.rs",
        ),
        (
            "capability invocation phase",
            "packages/agent/src/domains/agent/runner/agent/turn_runner/capability_invocations.rs",
        ),
        (
            "capability invocation stored payloads",
            "packages/agent/src/domains/session/event_store/types/payloads/capability_invocation.rs",
        ),
        (
            "session activity projection",
            "packages/agent/src/domains/session/event_store/sqlite/repositories/session/projections.rs",
        ),
    ];
    for (label, path) in identity_paths {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "contractId",
                "implementationId",
                "functionId",
                "pluginId",
                "workerId",
                "schemaDigest",
                "catalogRevision",
                "trustTier",
                "riskLevel",
                "effectClass",
                "bindingDecision",
            ],
            label,
        );
    }
    for (label, path) in identity_paths
        .into_iter()
        .filter(|(_, path)| !path.ends_with("capability_invocation_executor.rs"))
    {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "contract_id",
                "implementation_id",
                "function_id",
                "plugin_id",
                "worker_id",
                "schema_digest",
                "catalog_revision",
                "trust_tier",
                "risk_level",
                "effect_class",
                "binding_decision",
            ],
            label,
        );
    }
}

#[test]
fn startup_context_has_no_product_policy_or_worker_managers() {
    for (label, path) in [
        ("server startup", "packages/agent/src/main_runtime.rs"),
        (
            "server runtime context",
            "packages/agent/src/shared/server/context.rs",
        ),
        (
            "domain registration context",
            "packages/agent/src/domains/worker.rs",
        ),
        (
            "agent domain deps",
            "packages/agent/src/domains/agent/deps.rs",
        ),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "SkillRegistry",
                "skill_registry",
                "MemoryRegistry",
                "memory_registry",
                "GuardrailEngine",
                "guardrail",
                "HookAbortTracker",
                "hook_abort_tracker",
                "HookEngine",
                "SubagentManager",
                "subagent_manager",
                "shared_subagent_manager",
                "ProcessManagerOps",
                "process_manager",
                "JobManagerOps",
                "job_manager",
                "OutputBufferRegistry",
                "output_buffer_registry",
                "CronState",
                "CronScheduler",
                "init_cron",
                "cron_scheduler",
                "McpState",
                "McpRouter",
                "init_mcp",
                "mcp_router",
                "transcription_engine",
                "CapabilityExecutionPolicy",
                "capability_execution_policy",
                "context_policy",
            ],
            label,
        );
    }
}

#[test]
fn retained_registered_contracts_do_not_encode_approval_or_policy_planes() {
    for (label, path) in [
        (
            "agent contract",
            "packages/agent/src/domains/agent/contract.rs",
        ),
        (
            "auth contract",
            "packages/agent/src/domains/auth/contract.rs",
        ),
        (
            "message domain",
            "packages/agent/src/domains/message/mod.rs",
        ),
        (
            "model contract",
            "packages/agent/src/domains/model/contract.rs",
        ),
        (
            "session contract",
            "packages/agent/src/domains/session/contract.rs",
        ),
        (
            "settings contract",
            "packages/agent/src/domains/settings/contract.rs",
        ),
        ("system domain", "packages/agent/src/domains/system/mod.rs"),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                ".approval_required(",
                ".high_risk_contract(",
                "approvalRequired",
                "approval required",
                "guardrail",
                "policy",
            ],
            label,
        );
    }
}

#[test]
fn engine_registration_policy_has_no_approval_metadata_exceptions() {
    let policy = read_repo_file("packages/agent/src/engine/policy.rs");
    assert_absent(
        &policy,
        &[
            "requires approval metadata",
            "requires_approval_for_agent_visibility",
            "sandboxAutonomy",
            "conditionalApproval",
            "approvalRequiredFor",
            "highRiskContract",
        ],
        "engine registration policy",
    );

    let types = read_repo_file("packages/agent/src/engine/types.rs");
    assert_absent(
        &types,
        &[
            "requires_approval_for_agent_visibility",
            "requires explicit approval metadata",
        ],
        "engine effect helpers",
    );
}

#[test]
fn self_authored_worker_pack_primitives_are_not_registered_or_left_on_disk() {
    let primitives = read_repo_file("packages/agent/src/engine/primitives/mod.rs");
    assert_absent(
        &primitives,
        &[
            "MODULE_WORKER_ID",
            "module::registrations",
            "primitive_worker(MODULE_WORKER_ID",
            ".with_namespace_claim(\"worker_package\")",
            ".with_namespace_claim(\"module_config\")",
            ".with_namespace_claim(\"activation_record\")",
        ],
        "engine primitive registration",
    );

    let runtime = read_repo_file("packages/agent/src/engine/primitives/runtime.rs");
    assert_absent(
        &runtime,
        &[
            "mod worker_protocol",
            "worker::PROTOCOL_GUIDE_FUNCTION",
            "worker_protocol::guide",
        ],
        "host-dispatched primitive runtime",
    );

    let worker = read_repo_file("packages/agent/src/engine/primitives/worker.rs");
    assert_absent(
        &worker,
        &[
            "PROTOCOL_GUIDE_FUNCTION",
            "worker::protocol_guide",
            "worker::spawn",
            "sandbox-created",
            "pythonTemplate",
            "spawnWorkerPayloadExample",
            "worker pack",
        ],
        "worker primitive contracts",
    );

    for path in [
        "packages/agent/src/engine/primitives/module.rs",
        "packages/agent/src/engine/primitives/module",
        "packages/agent/src/engine/primitives/action_summary.rs",
        "packages/agent/src/engine/primitives/control/actions.rs",
        "packages/agent/src/engine/primitives/runtime/worker_protocol.rs",
        "packages/agent/src/engine/primitives/runtime/worker_protocol_template.py",
        "packages/agent/src/engine/primitives/ui/authoring",
        "packages/agent/src/engine/primitives/ui/authoring/source_control.rs",
        "packages/agent/src/engine/primitives/ui/authoring/actions.rs",
        "packages/agent/src/engine/host/module_jobs.rs",
        "packages/agent/src/engine/tests/module_activation.rs",
        "packages/agent/src/engine/tests/module_activation",
    ] {
        assert_repo_path_absent(path, "self-authored worker-pack substrate");
    }

    let readme = read_repo_file("README.md");
    assert_absent(
        &readme,
        &[
            "module::",
            "worker::spawn",
            "worker::protocol_guide",
            "worker pack",
            "worker packs",
            "sandbox-created",
        ],
        "README",
    );
}

#[test]
fn capability_registry_recipe_and_conformance_scaffolding_is_deleted() {
    for path in [
        "packages/agent/src/domains/capability/registry",
        "packages/agent/src/domains/capability/embeddings.rs",
        "packages/agent/src/domains/capability/types.rs",
        "packages/agent/src/domains/capability/operations/admin.rs",
        "packages/agent/src/domains/capability/operations/audit.rs",
        "packages/agent/src/domains/capability/operations/execute.rs",
        "packages/agent/src/domains/capability/operations/inspect.rs",
        "packages/agent/src/domains/capability/operations/policy_profile.rs",
        "packages/agent/src/domains/capability/operations/presentation.rs",
        "packages/agent/src/domains/capability/operations/run.rs",
        "packages/agent/src/domains/capability/operations/schema_validation.rs",
        "packages/agent/src/domains/capability/operations/search.rs",
        "packages/agent/src/domains/capability/operations/target_arguments.rs",
        "packages/agent/src/domains/capability/operations/target_resolution.rs",
        "packages/agent/src/domains/capability/operations/tests",
    ] {
        assert_repo_path_absent(path, "capability catalog scaffold");
    }

    for (label, path) in [
        (
            "capability module docs",
            "packages/agent/src/domains/capability/mod.rs",
        ),
        (
            "capability contract",
            "packages/agent/src/domains/capability/contract.rs",
        ),
        (
            "primitive execute implementation",
            "packages/agent/src/domains/capability/operations/mod.rs",
        ),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "capability registry",
                "registry",
                "recipe",
                "recipes",
                "plugin",
                "plugins",
                "binding",
                "bindings",
                "conformance",
                "vector search",
                "policy profile",
                "policy-profile",
                "capability::search",
                "capability::inspect",
            ],
            label,
        );
    }

    let readme = read_repo_file("README.md");
    assert_absent(
        &readme,
        &[
            "capability registry",
            "capability-registry",
            "registry/index projection",
            "capability::registry",
            "CapabilityRegistrySnapshot",
            "capability recipes",
            "capability::search",
            "capability::inspect",
            "vector search",
            "policy profile",
            "policy-profile",
        ],
        "README capability substrate references",
    );
}

#[test]
fn agent_trace_records_are_first_class_and_agent_visible() {
    let migration = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
    );
    for required in [
        "CREATE TABLE IF NOT EXISTS trace_records",
        "trace_id",
        "invocation_id",
        "parent_invocation_id",
        "provider_invocation_id",
        "session_id",
        "workspace_id",
        "turn",
        "model_primitive_name",
        "operation",
        "status",
        "record_json",
        "idx_trace_records_trace",
        "idx_trace_records_session",
        "idx_trace_records_invocation",
    ] {
        assert!(
            migration.contains(required),
            "fresh schema must persist first-class trace record field/index: {required}"
        );
    }

    let trace_types = read_repo_file("packages/agent/src/domains/session/event_store/trace.rs");
    for required in [
        "AGENT_TRACE_VERSION",
        "TRON_TRACE_METADATA_KEY",
        "AgentTraceRecord",
        "provider_invocation_id",
        "model_primitive_name",
        "record_json: Value",
        "AgentTraceListOptions",
    ] {
        assert!(
            trace_types.contains(required),
            "trace type module missing required primitive trace type text: {required}"
        );
    }

    let trace_repo = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/repositories/trace.rs",
    );
    for required in [
        "INSERT INTO trace_records",
        "UPDATE trace_records",
        "FROM trace_records",
        "WHERE session_id = ?1 AND trace_id = ?2",
        "ORDER BY timestamp DESC",
        "serde_json::from_str",
    ] {
        assert!(
            trace_repo.contains(required),
            "trace repository missing durable query/storage behavior: {required}"
        );
    }

    let trace_log = read_repo_file(
        "packages/agent/src/domains/session/event_store/store/event_store/trace_log.rs",
    );
    for required in [
        "append_trace_record",
        "update_trace_record",
        "get_trace_record",
        "list_trace_records",
    ] {
        assert!(
            trace_log.contains(required),
            "event store trace log missing required method: {required}"
        );
    }

    let contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    for required in [
        "trace_list",
        "trace_get",
        "log_recent",
        "inspect agent trace/log records",
        "\"traceRecordId\"",
        "\"traceId\"",
    ] {
        assert!(
            contract.contains(required),
            "execute contract must expose agent-visible trace query operation: {required}"
        );
    }

    let operations = read_repo_file("packages/agent/src/domains/capability/operations/mod.rs");
    for required in [
        "append_trace_record(&trace_record)",
        "update_trace_record(&trace_record)",
        "execute_operation(&operation",
        "\"trace_list\" => trace_list",
        "\"trace_get\" => trace_get",
        "\"log_recent\" => log_recent",
        "AgentTraceListOptions",
        "AGENT_TRACE_VERSION",
        "TRON_TRACE_METADATA_KEY",
        "\"providerInvocationId\"",
        "\"modelId\"",
        "\"provider\"",
        "\"workingDirectory\"",
        "workingDirectoryError",
        "\"authority\"",
        "\"requestHash\"",
        "\"resultHash\"",
        "\"content_hash\"",
        "\"model_id\"",
        "RUNTIME_METADATA_PROVIDER_TYPE",
        "trace_working_directory_metadata",
        "normalize_working_directory",
        "git_vcs",
        "execute::log_recent",
    ] {
        assert!(
            operations.contains(required),
            "execute operation trace wrapper missing primitive trace behavior: {required}"
        );
    }
    assert_absent(
        &operations,
        &[
            "observability::trace_get",
            "observability::trace_list",
            "capability::search",
            "capability::inspect",
        ],
        "primitive execute trace path",
    );

    let primitive_surface =
        read_repo_file("packages/agent/src/domains/agent/runner/agent/primitive_surface.rs");
    assert!(
        primitive_surface.contains("\"capability.execute\""),
        "primitive surface resolver must authorize the one execute primitive"
    );
    assert_absent(
        &primitive_surface,
        &["capability.search", "capability.inspect"],
        "primitive surface resolver",
    );
    assert_repo_path_absent(
        "packages/agent/src/domains/capability_support",
        "top-level capability_support domain abstraction",
    );

    let executor = read_repo_file(
        "packages/agent/src/domains/agent/runner/agent/capability_invocation_executor.rs",
    );
    for required in [
        "RUNTIME_METADATA_PROVIDER_INVOCATION_ID",
        "RUNTIME_METADATA_PROVIDER_TYPE",
        "RUNTIME_METADATA_WORKING_DIRECTORY",
        "RUNTIME_METADATA_MODEL_PRIMITIVE_NAME",
        "RUNTIME_METADATA_TURN",
        "RUNTIME_METADATA_RUN_ID",
        ".with_scope(\"capability.execute\")",
    ] {
        assert!(
            executor.contains(required),
            "capability executor must attach trusted trace runtime metadata: {required}"
        );
    }
    assert_absent(
        &executor,
        &["capability.search", "capability.inspect"],
        "capability executor authority envelope",
    );

    let integration_test = read_repo_file("packages/agent/tests/primitive_trace_execution.rs");
    for required in [
        "execute_file_write_records_agent_trace_and_trace_list_exposes_it",
        "execute_process_run_expands_home_alias_in_trace_working_directory",
        "execute_log_recent_exposes_bounded_session_trace_logs",
        "\"operation\": \"trace_list\"",
        "\"operation\": \"trace_get\"",
        "\"operation\": \"process_run\"",
        "\"operation\": \"log_recent\"",
        "\"provider-call-write-1\"",
        "\"provider-call-get-1\"",
        "\"provider-call-pwd-1\"",
        "\"gpt-5.5\"",
        "\"workingDirectory\"",
        "\"model_id\"",
        "\"content_hash\"",
    ] {
        assert!(
            integration_test.contains(required),
            "trace integration proof missing required evidence assertion: {required}"
        );
    }

    let readme = read_repo_file("README.md");
    for required in [
        "trace_list",
        "trace_get",
        "trace_records",
        "provider type",
        "canonical working directory",
    ] {
        assert!(
            readme.contains(required),
            "README must document primitive traceability surface: {required}"
        );
    }
    assert_absent(
        &readme,
        &["observability::trace_get", "observability::trace_list"],
        "README model-visible trace documentation",
    );
}

#[test]
fn primitive_branch_has_no_product_update_surface() {
    assert_repo_path_absent(
        "packages/agent/src/platform/updater",
        "server user-mode updater module",
    );
    assert_repo_path_absent(
        "packages/agent/src/domains/settings/implementation/types/update.rs",
        "server update settings schema",
    );

    let retained_source = read_repo_source_trees(&[
        "packages/agent/src",
        "packages/ios-app/Sources",
        "packages/ios-app/Tests",
        "packages/mac-app/Sources",
        "packages/mac-app/Tests",
    ]);
    assert_absent(
        &retained_source,
        &[
            "platform::updater",
            "pub mod updater",
            "system::check_for_updates",
            "system::get_update_status",
            "SystemCheckForUpdatesResult",
            "SystemUpdateStatusResult",
            "checkForUpdates",
            "getUpdateStatus",
            "UpdateSettings",
            "UpdateChannel",
            "UpdateFrequency",
            "UpdateAction",
            "updateEnabled",
            "updateChannel",
            "updateFrequency",
            "updateAction",
            "updater-state.json",
            "auto-update.pause",
            "server.update_available",
            "release_fetcher",
            "updater_state_path",
        ],
        "retained source product update surface",
    );

    let scripts = [
        "scripts/tron",
        "scripts/tron-lib.sh",
        "scripts/tron.d/automation.sh",
        "scripts/auto-deploy",
    ]
    .into_iter()
    .map(read_repo_file)
    .collect::<Vec<_>>()
    .join("\n");
    assert_absent(
        &scripts,
        &["self-update", "auto-update.pause", "updater-state.json"],
        "CLI product update surface",
    );

    let bundled_profile = read_repo_file("packages/agent/defaults/profiles/default/profile.toml");
    assert_absent(
        &bundled_profile,
        &["[settings.server.update]", "server.update"],
        "bundled default profile update settings",
    );
}

#[test]
fn prompt_media_uses_unified_attachment_primitive() {
    let rust_files = [
        "packages/agent/src/domains/agent/contract.rs",
        "packages/agent/src/domains/agent/operations/prompt.rs",
        "packages/agent/src/domains/agent/runtime/service/request.rs",
        "packages/agent/src/domains/agent/runtime/service/execute.rs",
        "packages/agent/src/domains/agent/runtime/service/queue.rs",
        "packages/agent/src/domains/agent/runtime/runtime/user_event.rs",
    ];
    for path in rust_files {
        let source = read_repo_file(path);
        assert!(
            source.contains("attachments") || source.contains("FileAttachment"),
            "{path} must keep the unified prompt attachment primitive"
        );
        assert_absent(
            &source,
            &[
                "\"images\"",
                "opt_array(params, \"images\")",
                "validate_attachment_arrays",
                "pub images",
                "images.as_deref()",
                "mediaType",
            ],
            path,
        );
    }

    let ios_files = [
        "packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Agent.swift",
        "packages/ios-app/Sources/Services/Network/Clients/AgentClient.swift",
        "packages/ios-app/Sources/Services/Network/Clients/AgentClientProtocol.swift",
        "packages/ios-app/Sources/Core/Repositories/Protocols/AgentRepository.swift",
        "packages/ios-app/Sources/Core/Repositories/DefaultAgentRepository.swift",
        "packages/ios-app/Sources/ViewModels/Chat/ChatViewModel+Messaging.swift",
        "packages/ios-app/Tests/Services/AgentClientTests.swift",
        "packages/ios-app/Tests/Repositories/DefaultAgentRepositoryTests.swift",
        "packages/ios-app/Tests/Models/EngineProtocolTypesTests.swift",
    ];
    for path in ios_files {
        let source = read_repo_file(path);
        assert!(
            source.contains("attachments") || source.contains("FileAttachment"),
            "{path} must keep the unified prompt attachment primitive"
        );
        assert_absent(
            &source,
            &[
                "ImageAttachment",
                "lastImages",
                "lastSendPromptImages",
                "images:",
                "\"images\"",
            ],
            path,
        );
    }
}

#[test]
fn ios_shell_has_no_fixed_session_tree_projection() {
    for (path, label) in [
        (
            "packages/ios-app/Sources/Views/SessionTree",
            "fixed iOS session-tree view root",
        ),
        (
            "packages/ios-app/Sources/Database/Repositories/TreeRepository.swift",
            "fixed local event-tree repository",
        ),
        (
            "packages/ios-app/Sources/Services/Events/EventTreeBuilder.swift",
            "fixed local event-tree projection builder",
        ),
        (
            "packages/ios-app/Tests/Infrastructure/TreeRepositoryTests.swift",
            "fixed local event-tree repository tests",
        ),
        (
            "packages/ios-app/Tests/Views/ForkButtonTests.swift",
            "fixed fork-row tests",
        ),
        (
            "packages/ios-app/Tests/Views/EventIconProviderTests.swift",
            "fixed session-tree icon provider tests",
        ),
    ] {
        assert_repo_path_absent(path, label);
    }

    let retained_ios = read_repo_source_trees(&[
        "packages/ios-app/Sources",
        "packages/ios-app/Tests",
        "packages/ios-app/project.yml",
    ]);
    assert_absent(
        &retained_ios,
        &[
            "EventTreeNode",
            "EventTreeBuilder",
            "TreeRepository",
            "ForkPointIndicator",
            "ForkButtonState",
            "EventIconProvider",
            "getTreeVisualization",
            "database.tree",
            "eventDB.tree",
            "isBranchPoint",
        ],
        "retained iOS session-tree projection surface",
    );
}

#[test]
fn approval_and_observability_planes_are_not_engine_primitives() {
    for (path, label) in [
        (
            "packages/agent/src/engine/approval.rs",
            "engine approval record/store module",
        ),
        (
            "packages/agent/src/engine/approval",
            "engine approval store support directory",
        ),
        (
            "packages/agent/src/engine/primitives/approval.rs",
            "approval primitive worker",
        ),
        (
            "packages/agent/src/engine/primitives/observability.rs",
            "observability primitive worker",
        ),
        (
            "packages/agent/src/engine/tests/approval.rs",
            "approval primitive tests",
        ),
        (
            "packages/agent/src/engine/tests/approval_autonomy.rs",
            "approval autonomy tests",
        ),
        (
            "packages/agent/src/engine/tests/trace_observability.rs",
            "old observability trace tests",
        ),
    ] {
        assert_repo_path_absent(path, label);
    }

    let engine_mod = read_repo_file("packages/agent/src/engine/mod.rs");
    assert_absent(
        &engine_mod,
        &[
            "pub mod approval;",
            "pub use approval",
            "EngineApprovalRecord",
            "EngineApprovalRequest",
            "SqliteEngineApprovalStore",
        ],
        "engine root exports",
    );

    let primitives = read_repo_file("packages/agent/src/engine/primitives/mod.rs");
    assert_absent(
        &primitives,
        &[
            "mod approval;",
            "mod observability;",
            "APPROVAL_WORKER_ID",
            "OBSERVABILITY_WORKER_ID",
            "APPROVAL_REQUEST_FUNCTION",
            "APPROVAL_RESOLVE_FUNCTION",
            "approval::registrations",
            "observability::registrations",
            "ApprovalStoreBackend",
            "parse_approval_status",
        ],
        "engine primitive registrations",
    );

    let capability_client = read_repo_file("packages/agent/src/engine/capabilities.rs");
    assert_absent(
        &capability_client,
        &[
            "AutonomyApprovalPromptMode",
            "EngineApprovalRequest",
            "EngineApprovalTargetMetadata",
            "approval_required",
            "request_approval",
            "auto_approve_and_invoke",
            "approval primitives are owned",
        ],
        "agent capability client",
    );

    let host = read_repo_file("packages/agent/src/engine/host.rs");
    assert_absent(
        &host,
        &[
            "EngineApprovalRecord",
            "EngineApprovalRequest",
            "EngineApprovalTargetMetadata",
            "EngineAutoApprovalOutcome",
            "APPROVAL_REQUEST_FUNCTION",
            "APPROVAL_RESOLVE_FUNCTION",
        ],
        "engine host root",
    );

    for (path, label) in [
        (
            "packages/agent/src/engine/host/invocation_handle.rs",
            "engine host invocation path",
        ),
        (
            "packages/agent/src/engine/host/substrate_handle.rs",
            "engine host substrate methods",
        ),
        (
            "packages/agent/src/engine/primitives/runtime.rs",
            "engine primitive runtime",
        ),
        (
            "packages/agent/src/domains/session/reconstruct.rs",
            "session reconstruction",
        ),
        ("README.md", "README"),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "approval::",
                "approval.pending",
                "approval.resolved",
                "engine_approvals",
                "approvalItems",
                "observability::",
                "OBSERVABILITY",
                "requiresApproval",
            ],
            label,
        );
    }

    for (path, label) in [
        ("README.md", "README primitive branch docs"),
        ("packages/agent/src/domains/catalog.rs", "domain catalog"),
        (
            "packages/agent/src/domains/registration.rs",
            "domain registration",
        ),
        (
            "packages/agent/src/domains/session/reconstruct.rs",
            "session reconstruction",
        ),
        (
            "packages/agent/src/domains/settings/implementation/types/server.rs",
            "server settings",
        ),
        (
            "packages/agent/src/engine/capabilities.rs",
            "capability client",
        ),
        ("packages/agent/src/engine/grants.rs", "grant store"),
        ("packages/agent/src/engine/grants/model.rs", "grant model"),
        (
            "packages/agent/src/engine/grants/sqlite_codec.rs",
            "grant sqlite codec",
        ),
        ("packages/agent/src/engine/mod.rs", "engine docs/root"),
        ("packages/agent/src/engine/policy.rs", "engine policy"),
        (
            "packages/agent/src/engine/primitives/action_summary.rs",
            "action summary projection",
        ),
        (
            "packages/agent/src/engine/primitives/control/actions.rs",
            "control action projection",
        ),
        (
            "packages/agent/src/engine/primitives/grant.rs",
            "grant primitive",
        ),
        (
            "packages/agent/src/engine/primitives/runtime.rs",
            "runtime primitive",
        ),
        (
            "packages/agent/src/engine/primitives/ui.rs",
            "ui primitive target validation",
        ),
        (
            "packages/agent/src/engine/primitives/ui/authoring/actions.rs",
            "generated ui action authoring",
        ),
        (
            "packages/agent/src/engine/primitives/worker.rs",
            "worker primitive",
        ),
        (
            "packages/agent/src/engine/resources/definitions.rs",
            "resource definitions",
        ),
        (
            "packages/agent/src/engine/resources/ui_surface.rs",
            "ui surface resource validation",
        ),
        (
            "packages/agent/src/engine/tests/catalog_discovery.rs",
            "catalog tests",
        ),
        (
            "packages/agent/src/engine/tests/external_worker.rs",
            "external worker tests",
        ),
        (
            "packages/agent/src/engine/tests/generated_ui.rs",
            "generated ui tests",
        ),
        (
            "packages/agent/src/engine/tests/grant_authority.rs",
            "grant tests",
        ),
        (
            "packages/agent/src/engine/tests/leases_compensation.rs",
            "lease/compensation tests",
        ),
        (
            "packages/agent/src/engine/tests/meta_primitives.rs",
            "meta primitive tests",
        ),
        (
            "packages/agent/src/engine/tests/resource_kernel.rs",
            "resource tests",
        ),
        (
            "packages/agent/src/engine/tests/restart_chaos.rs",
            "restart tests",
        ),
        (
            "packages/agent/src/engine/tests/state_queue.rs",
            "state/queue tests",
        ),
        (
            "packages/agent/src/engine/tests/support.rs",
            "engine test support",
        ),
        ("packages/agent/src/engine/types.rs", "engine core types"),
        ("packages/agent/src/transport/engine.rs", "engine transport"),
    ] {
        if !repo_path(path).exists() {
            continue;
        }
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "approval",
                "Approval",
                "approvalPolicy",
                "approvalRequired",
                "approval_required",
                "approvalPromptMode",
                "with_approval_required",
                "AutonomyApprovalPromptMode",
                "ApprovalStatus",
                "engine_approvals",
                "approvalItems",
                "requiresApproval",
                "observability::",
            ],
            label,
        );
    }
}

#[test]
fn capability_policy_settings_plane_is_deleted() {
    assert_repo_path_absent(
        "packages/agent/src/domains/settings/implementation/types/capabilities.rs",
        "capability-specific settings type module",
    );

    for (path, label) in [
        (
            "packages/agent/defaults/profiles/default/profile.toml",
            "default profile",
        ),
        (
            "packages/agent/src/domains/settings/implementation/types/mod.rs",
            "settings root type",
        ),
        (
            "packages/agent/src/domains/settings/implementation/storage/loader.rs",
            "settings loader tests",
        ),
        (
            "packages/agent/src/shared/foundation/profile/tests.rs",
            "profile overlay tests",
        ),
        ("README.md", "README settings docs"),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "settings.capabilities",
                "[settings.capabilities",
                "CapabilitySettings",
                "capabilities.process",
                "capabilities.search",
                "ProcessCapabilitySettings",
                "FilesystemReadCapabilitySettings",
                "BrowserSettings",
                "ComputerUseSettings",
            ],
            label,
        );
    }
}

#[test]
fn public_context_capability_plane_is_deleted() {
    assert_repo_path_absent(
        "packages/agent/src/domains/context",
        "public context domain worker",
    );

    for (path, label) in [
        (
            "packages/agent/src/domains/mod.rs",
            "domain module registry",
        ),
        (
            "packages/agent/src/domains/registration.rs",
            "domain startup registration",
        ),
        (
            "packages/agent/src/domains/catalog.rs",
            "canonical capability catalog",
        ),
        ("README.md", "README context docs"),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "context::worker_module",
                "super::context::contract",
                "context::get_snapshot",
                "context::get_detailed_snapshot",
                "context::preview_compaction",
                "context::should_compact",
                "context::confirm_compaction",
                "context::compact",
                "context::can_accept_turn",
                "context::get_audit_trace",
            ],
            label,
        );
    }
}

#[test]
fn fresh_session_store_has_no_product_tables_or_old_shape_migrations() {
    let migration = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
    );
    let migration_runner =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/migrations/mod.rs");
    let repositories =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/repositories/mod.rs");
    let row_types =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/row_types.rs");
    let session_repo = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/repositories/session.rs",
    );

    assert_absent(
        &migration,
        &[
            "branches",
            "device_tokens",
            "cron_jobs",
            "cron_runs",
            "constitution_",
            "profile_migrations",
            "spawning_session_id",
            "spawn_type",
            "spawn_task",
            "origin",
            "source",
            "profile",
            "use_worktree",
        ],
        "fresh session schema",
    );
    assert_absent(
        &migration_runner,
        &[
            "v002_",
            "v004_",
            "v005_",
            "migrated v001",
            "historical-shape",
            "already recorded v001",
        ],
        "migration runner",
    );
    assert_absent(
        &repositories,
        &["branch", "constitution", "device_token"],
        "session store repositories",
    );
    assert_absent(
        &row_types,
        &[
            "BranchRow",
            "DeviceTokenRow",
            "spawning_session_id",
            "spawn_type",
            "spawn_task",
            "origin",
            "source",
            "profile",
            "use_worktree",
        ],
        "session store row types",
    );
    assert_absent(
        &session_repo,
        &[
            "exclude_subagents",
            "list_subagents",
            "update_spawn_info",
            "update_source",
            "NORMAL_PROFILE",
            "use_worktree",
            "source = '",
        ],
        "session repository",
    );
}

#[test]
fn retained_event_payload_surface_is_loop_owned() {
    let payloads =
        read_repo_file("packages/agent/src/domains/session/event_store/types/payloads/mod.rs");
    let generated =
        read_repo_file("packages/agent/src/domains/session/event_store/types/generated.rs");
    let pause_requested = ["Capability", "Pause", "Requested"].concat();
    let pause_resolved = ["Capability", "Pause", "Resolved"].concat();

    assert_absent(
        &payloads,
        &[
            "pub mod device;",
            "pub mod file;",
            "pub mod hook;",
            "pub mod memory;",
            "pub mod notification;",
            "pub mod repo;",
            "pub mod rules;",
            "pub mod skill;",
            "pub mod subagent;",
            "pub mod todo;",
            "pub mod worktree;",
        ],
        "typed payload module surface",
    );
    assert_absent(
        &generated,
        &[
            "MessageQueued",
            "MessageDequeued",
            pause_requested.as_str(),
            pause_resolved.as_str(),
            "CapabilityRunStatus",
            "ConfigModelSwitch",
            "ConfigPromptUpdate",
            "ConfigReasoningLevel",
            "Notification",
            "Skill",
            "Rules",
            "File",
            "Worktree",
            "Subagent",
            "ProcessResults",
            "UserJob",
            "Todo",
            "Hook",
            "Memory",
            "Repo",
            "DeviceToken",
            "ServerUpdateAvailable",
            "is_worktree_type",
            "is_repo_type",
            "is_subagent_type",
            "is_hook_type",
            "is_skill_type",
            "is_rules_type",
            "is_queue_type",
            "is_file_type",
            "is_server_type",
        ],
        "generated event type surface",
    );
}

#[test]
fn diagnostics_logging_surface_is_flattened_to_execute_evidence() {
    assert_repo_path_absent(
        "packages/agent/src/shared/logging/store.rs",
        "unused generic log query abstraction",
    );

    let logging_mod = read_repo_file("packages/agent/src/shared/logging/mod.rs");
    let logging_types = read_repo_file("packages/agent/src/shared/logging/types.rs");
    for (source, label) in [
        (logging_mod.as_str(), "shared logging module"),
        (logging_types.as_str(), "shared logging types"),
    ] {
        assert_absent(
            source,
            &["LogStore", "LogEntry", "LogQueryOptions", "SortOrder"],
            label,
        );
    }

    let system_surface = read_repo_file("packages/agent/src/domains/system/mod.rs");
    assert_absent(
        &system_surface,
        &[
            "system::get_diagnostics",
            "get_diagnostics",
            "system_diagnostics_value",
        ],
        "system debug diagnostics surface",
    );

    let settings_surface = [
        read_repo_file("packages/agent/src/domains/settings/implementation/types/server.rs"),
        read_repo_file("packages/agent/defaults/profiles/default/profile.toml"),
        read_repo_file(
            "packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Settings.swift",
        ),
        read_repo_file("packages/ios-app/Sources/ViewModels/State/SettingsState.swift"),
        read_repo_file(
            "packages/ios-app/Sources/Views/Settings/Pages/ConnectionSettingsPage.swift",
        ),
        read_repo_file("README.md"),
    ]
    .join("\n");
    assert_absent(
        &settings_surface,
        &[
            "payloadCapture",
            "maxInlinePayloadBytes",
            "PayloadCapture",
            "observabilityPayloadCapture",
            "observabilityMaxInlinePayloadBytes",
            "Inline bytes",
        ],
        "retained observability settings surface",
    );

    let execute_contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    let execute_ops = read_repo_file("packages/agent/src/domains/capability/operations/mod.rs");
    let trace_proof = read_repo_file("packages/agent/tests/primitive_trace_execution.rs");
    for (source, label) in [
        (execute_contract.as_str(), "execute contract"),
        (execute_ops.as_str(), "execute operations"),
        (trace_proof.as_str(), "primitive trace/log proof"),
    ] {
        assert!(
            source.contains("log_recent"),
            "{label} must expose log evidence through the single execute primitive"
        );
    }

    let ios_surface = [
        read_repo_file("packages/ios-app/Sources/Services/Network/Clients/MiscClient.swift"),
        read_repo_file(
            "packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+System.swift",
        ),
        read_repo_file("packages/ios-app/Sources/Views/Settings/SettingsSupport.swift"),
        read_repo_file(
            "packages/ios-app/Sources/Views/Settings/Pages/ConnectionSettingsPage.swift",
        ),
    ]
    .join("\n");
    assert_absent(
        &ios_surface,
        &[
            "SystemDiagnosticsResult",
            "getDiagnostics",
            "system::get_diagnostics",
            "ConnectionSettingsServerBackedSection",
            "diagnosticsSection",
        ],
        "retained iOS diagnostics settings surface",
    );
    assert!(
        ios_surface.contains("runtimeEvidenceSection"),
        "iOS settings should render the one retained evidence section directly"
    );
}

#[test]
fn dynamic_runtime_surfaces_are_schema_rendering_not_target_authoring() {
    assert_repo_path_absent(
        "packages/agent/src/engine/primitives/ui/authoring",
        "server-owned generated UI target authoring",
    );
    assert_repo_path_absent(
        "packages/agent/src/engine/primitives/action_summary.rs",
        "server-owned UI action summary projection",
    );
    assert_repo_path_absent(
        "packages/agent/src/engine/primitives/control/actions.rs",
        "server-owned UI control action projection",
    );

    let rust_surface = [
        read_repo_file("packages/agent/src/engine/primitives/ui.rs"),
        read_repo_file("packages/agent/src/engine/primitives/ui/schemas.rs"),
        read_repo_file("packages/agent/src/engine/primitives/ui/validation.rs"),
        read_repo_file("packages/agent/src/engine/resources/types.rs"),
        read_repo_file("packages/agent/src/engine/resources/ui_surface.rs"),
    ]
    .join("\n");
    assert_absent(
        &rust_surface,
        &[
            "ui::catalog",
            "ui::surface_for_target",
            "ui::refresh_surface",
            "ui_component_catalog",
            "UI_CATALOG_ID",
            "UI_CATALOG_REVISION",
            "SurfaceAuthoringRequest",
            "author_surface_for_target",
            "targetFunctionId",
            "requiredGrant",
            "requiredRisk",
            "targetRevision",
            "payloadTemplate",
            "idempotencyKeyTemplate",
            "WorkerRef",
            "\"bindings\"",
            "\"authoring\"",
            "\"redactionPolicy\"",
            "\"refreshPolicy\"",
        ],
        "retained Rust dynamic surface primitive",
    );

    let ios_surface = [
        read_repo_file(
            "packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+GeneratedUI.swift",
        ),
        read_repo_file(
            "packages/ios-app/Sources/Views/DynamicSurfaces/GeneratedRuntimeSurfaceView.swift",
        ),
        read_repo_file("packages/ios-app/Tests/Models/EngineProtocol/GeneratedUIDTOTests.swift"),
        read_repo_file("packages/ios-app/Tests/Views/GeneratedUIRendererTests.swift"),
    ]
    .join("\n");
    assert_absent(
        &ios_surface,
        &[
            "UiCatalog",
            "catalogId",
            "catalogRevision",
            "targetFunctionId",
            "requiredGrant",
            "requiredRisk",
            "targetRevision",
            "payloadTemplate",
            "idempotencyKeyTemplate",
            "UiBindingDTO",
            "UiSurfaceAuthoringDTO",
            "UiSurfaceForTargetRequestDTO",
            "UiSurfaceRefreshRequestDTO",
            "WorkerRef",
            "workerId",
            "bindings",
            "authoring",
            "redactionPolicy",
            "refreshPolicy",
        ],
        "retained iOS dynamic runtime surface",
    );
    assert!(
        ios_surface.contains("schemaVersion"),
        "dynamic runtime surfaces should keep one explicit schema version primitive"
    );
}

#[test]
fn queue_trigger_and_prompt_envelopes_do_not_pin_preexecution_catalog_state() {
    let retained_envelope = [
        read_repo_file("packages/agent/src/engine/queue.rs"),
        read_repo_file("packages/agent/src/engine/queue/runtime.rs"),
        read_repo_file("packages/agent/src/engine/queue/sqlite_codec.rs"),
        read_repo_file("packages/agent/src/engine/primitives/queue.rs"),
        read_repo_file("packages/agent/src/engine/triggers.rs"),
        read_repo_file("packages/agent/src/engine/primitives/trigger.rs"),
        read_repo_file("packages/agent/src/engine/types.rs"),
        read_repo_file("packages/agent/src/engine/policy.rs"),
        read_repo_file("packages/agent/src/domains/agent/operations/prompt.rs"),
        read_repo_file("packages/agent/src/domains/agent/runtime/service/deps.rs"),
        read_repo_file("packages/agent/src/domains/agent/runtime/service/events.rs"),
        read_repo_file("packages/agent/src/domains/agent/runtime/service/execute.rs"),
        read_repo_file("packages/agent/src/domains/agent/runtime/service/queue.rs"),
        read_repo_file("packages/agent/src/domains/agent/stream.rs"),
    ]
    .join("\n");
    assert_absent(
        &retained_envelope,
        &[
            "targetRevision",
            "target_revision",
            "expectedFunctionRevision",
            "expected_function_revision",
            "targetFunctionId",
            "catalogRevision",
        ],
        "retained queue/trigger/prompt runtime envelope",
    );
}

#[test]
fn engine_invocation_and_transport_do_not_require_expected_revision_tokens() {
    let retained_invocation_surface = [
        read_repo_file("README.md"),
        read_repo_file("packages/agent/src/engine/host.rs"),
        read_repo_file("packages/agent/src/engine/host/meta.rs"),
        read_repo_file("packages/agent/src/engine/invocation.rs"),
        read_repo_file("packages/agent/src/engine/registry/invocation.rs"),
        read_repo_file("packages/agent/src/engine/protocol.rs"),
        read_repo_file("packages/agent/src/engine/external.rs"),
        read_repo_file("packages/agent/src/engine/ledger/outcome.rs"),
        read_repo_file("packages/agent/src/engine/errors.rs"),
        read_repo_file("packages/agent/src/transport/engine_ws.rs"),
        read_repo_file("packages/agent/src/transport/engine_ws/wire.rs"),
        read_repo_file("packages/agent/src/transport/contracts.rs"),
        read_repo_file("packages/agent/src/engine/tests/host_invocation.rs"),
        read_repo_file("packages/agent/src/engine/tests/meta_primitives.rs"),
        read_repo_file("packages/agent/src/engine/tests/external_worker.rs"),
        read_repo_file("packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes.swift"),
        read_repo_file("packages/ios-app/Sources/Services/Network/EngineConnection.swift"),
        read_repo_file(
            "packages/ios-app/Sources/Services/Network/EngineConnectionProtocolFrames.swift",
        ),
    ]
    .join("\n");
    assert_absent(
        &retained_invocation_surface,
        &[
            "expectedFunctionRevision",
            "expected_function_revision",
            "expectedRevision",
            "expected_revision",
            "expecting_revision",
            "StaleFunctionRevision",
            "stale_function_revision",
        ],
        "retained engine invocation/transport surface",
    );
}

#[test]
fn control_projection_primitive_is_deleted() {
    let retained_control_surface = [
        read_repo_file("packages/agent/src/engine/primitives/mod.rs"),
        read_repo_file("packages/agent/src/engine/primitives/runtime.rs"),
        read_repo_file("packages/ios-app/project.yml"),
    ]
    .join("\n");
    assert_absent(
        &retained_control_surface,
        &[
            "CONTROL_WORKER_ID",
            "control::",
            "mod control",
            "ControlSnapshotDTO",
        ],
        "retained control projection registration surface",
    );
    assert!(
        !repo_path("packages/agent/src/engine/primitives/control.rs").exists(),
        "control primitive source should be deleted"
    );
    assert!(
        !repo_path(
            "packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Control.swift"
        )
        .exists(),
        "iOS control DTO should be deleted"
    );
}

#[test]
fn public_catalog_readout_state_is_not_client_envelope_state() {
    let transport_surface = [
        read_repo_file("packages/agent/src/transport/contracts.rs"),
        read_repo_file("packages/agent/src/transport/engine_ws.rs"),
        read_repo_file(
            "packages/ios-app/Sources/Services/Network/EngineConnectionProtocolFrames.swift",
        ),
    ]
    .join("\n");
    assert_absent(
        &transport_surface,
        &[
            "currentCatalogRevision",
            "\"catalogRevision\": catalog_revision",
            "let catalogRevision: UInt64?",
            "let currentCatalogRevision",
        ],
        "public engine transport envelope catalog readout surface",
    );
    let swift_protocol =
        read_repo_file("packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes.swift");
    let response_frame = swift_protocol
        .split("struct EngineProtocolResponseFrame")
        .nth(1)
        .and_then(|tail| tail.split("struct EngineFunctionCallEnvelope").next())
        .expect("EngineProtocolResponseFrame section should exist");
    assert_absent(
        response_frame,
        &["catalogRevision"],
        "iOS top-level response frame",
    );
    let function_call_envelope = swift_protocol
        .split("struct EngineFunctionCallEnvelope")
        .nth(1)
        .and_then(|tail| tail.split("struct EngineChildInvocation").next())
        .expect("EngineFunctionCallEnvelope section should exist");
    assert_absent(
        function_call_envelope,
        &["catalogRevision"],
        "iOS function-call envelope",
    );

    let public_catalog_read_surface = [
        read_repo_file("packages/agent/src/engine/host.rs"),
        read_repo_file("packages/agent/src/engine/host/meta.rs"),
        read_repo_file("packages/agent/src/engine/primitives/catalog.rs"),
        read_repo_file("packages/agent/src/engine/primitives/runtime.rs"),
        read_repo_file("packages/agent/src/engine/primitives/worker.rs"),
    ]
    .join("\n");
    assert_absent(
        &public_catalog_read_surface,
        &[
            "\"catalogRevision\": self.catalog.revision().0",
            "\"catalogRevision\": host.catalog_revision().0",
            "\"catalogRevision\": catalog_revision.0",
            "\"required\": [\"catalogRevision\"",
            "\"catalogRevision\": {\"type\": \"integer\"}",
        ],
        "public catalog/meta/worker readout catalog revision surface",
    );
}

#[test]
fn prompt_suggestion_lifecycle_state_is_deleted_from_retained_sources() {
    let retained_sources = read_repo_source_trees(&[
        "packages/agent/src",
        "packages/ios-app/Sources",
        "packages/ios-app/Tests",
        "packages/ios-app/project.yml",
    ]);
    let forbidden = [
        ["post", "Processing"].concat(),
        ["is", "Post", "Processing"].concat(),
        ["post", "-", "processing"].concat(),
        ["post", " processing"].concat(),
        ["awaiting", "Suggestions"].concat(),
        ["suggest", "-", "prompts"].concat(),
        ["Pull", "Up", "Panel"].concat(),
        ["Llm", "Hook", "Result"].concat(),
        ["hook", ".", "llm", "_", "result"].concat(),
    ];
    for token in forbidden {
        assert!(
            !retained_sources.contains(&token),
            "retained primitive sources must not contain deleted prompt-suggestion lifecycle token `{token}`"
        );
    }
}

#[test]
fn user_interaction_pause_plane_is_deleted_from_retained_sources() {
    let retained_sources = read_repo_source_trees(&[
        "packages/agent/src",
        "packages/ios-app/Sources",
        "packages/ios-app/Tests",
        "packages/ios-app/project.yml",
    ]);
    let forbidden = [
        ["User", "Interaction", "Invocation"].concat(),
        ["User", "Interaction", "Capability"].concat(),
        ["User", "Interaction", "Coordinator"].concat(),
        ["User", "Interaction", "State"].concat(),
        ["User", "Interaction", "Sheet"].concat(),
        ["User", "Interaction", "Viewer"].concat(),
        ["answered", "Questions"].concat(),
        ["submit", "Answers"].concat(),
        ["Submit", "Answers"].concat(),
        ["Answer", "Submission"].concat(),
        ["agent::", "submit", "_", "answers"].concat(),
        ["capability", ".", "pause", "."].concat(),
        ["Capability", "Pause"].concat(),
        ["pause", "Id"].concat(),
        ["prompt", "Payload"].concat(),
        ["answer", "Authority"].concat(),
        ["resume", "Schema"].concat(),
        ["interaction", "Status"].concat(),
        ["parsed", "Answers"].concat(),
        ["ask", "_", "user"].concat(),
        ["mark", "Pending", "Questions", "As", "Superseded"].concat(),
    ];
    for token in forbidden {
        assert!(
            !retained_sources.contains(&token),
            "retained primitive sources must not contain deleted user-interaction pause-plane token `{token}`"
        );
    }
}
