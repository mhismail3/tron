//! Static gates for the primitive engine teardown planning scorecard.

use std::path::PathBuf;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_root().join(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn assert_absent(haystack: &str, banned: &[&str], label: &str) {
    for needle in banned {
        assert!(
            !haystack.contains(needle),
            "{label} must not retain primitive-teardown-banned text `{needle}`"
        );
    }
}

#[test]
fn primitive_engine_teardown_plan_stays_formalized() {
    let scorecard = read_repo_file("packages/agent/docs/primitive-engine-teardown-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/primitive-engine-teardown-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# Primitive Engine Teardown Scorecard",
        "Current score: **63/100**",
        "Status: **active execution artifact**",
        "Branch: `codex/primitive-engine-teardown`",
        "There are no users and no compatibility obligations.",
        "No backward compatibility",
        "the model receives one initial tool, `execute`",
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
        "| PET-7 | Self-authored worker/capability substrate | 8 | pending |",
        "| PET-8 | iOS primitive shell | 10 | pending |",
        "| PET-9 | Documentation and managed asset rewrite | 5 | pending |",
        "| PET-10 | Absence gates and dead-code cleanup | 6 | pending |",
        "| PET-11 | End-to-end closeout and \"cannot remove more\" audit | 8 | pending |",
        "Total weight: **100**",
        "`provider_surface_exports_only_execute`",
        "`deleted_first_party_capabilities_are_absent`",
        "`context_has_soul_not_rules_or_skills`",
        "`ios_primary_shell_has_no_fixed_product_modes`",
        "`no_legacy_fallback_compatibility_paths`",
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
        "Current score: **63/100**",
        "Status: **active execution artifact**",
        "New teardown branch: `codex/primitive-engine-teardown`",
        "Compatibility assumption: none.",
        "| PET-0 | passed_after_fix |",
        "| PET-1 | passed_after_fix |",
        "| PET-2 | passed_after_fix |",
        "| PET-3 | passed_after_fix |",
        "| PET-4 | passed_after_fix |",
        "| PET-5 | passed_after_fix |",
        "| PET-6 | passed_after_fix |",
        "| PET-11 | pending |",
        "provider model-facing tool export proof",
        "iOS simulator target name, UDID, bundle id, launch return code",
    ] {
        assert!(
            manifest.contains(required),
            "primitive teardown evidence manifest missing required text: {required}"
        );
    }

    assert!(
        readme.contains("packages/agent/docs/primitive-engine-teardown-scorecard.md")
            && readme.contains("active")
            && readme.contains("clean-break primitive engine teardown scorecard")
            && readme
                .contains("packages/agent/docs/primitive-engine-teardown-evidence-manifest.md"),
        "README living-doc map must link the active primitive teardown scorecard and evidence manifest"
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
            "packages/agent/src/domains/capability_support/implementations/primitive_surface.rs",
        ),
    ] {
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
            "context domain deps",
            "packages/agent/src/domains/context/deps.rs",
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
            "context contract",
            "packages/agent/src/domains/context/contract.rs",
        ),
        (
            "message contract",
            "packages/agent/src/domains/message/contract.rs",
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
        (
            "system contract",
            "packages/agent/src/domains/system/contract.rs",
        ),
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
            "CapabilityPauseRequested",
            "CapabilityPauseResolved",
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
