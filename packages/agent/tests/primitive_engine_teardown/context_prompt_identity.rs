use super::support::*;

#[test]
fn context_has_soul_and_agent_state_not_rules_skills_hooks_or_policy_planes() {
    let messages = read_repo_file("packages/agent/src/shared/protocol/messages/mod.rs");
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
        read_repo_file(
            "packages/agent/src/domains/model/providers/anthropic/message_converter/mod.rs",
        ),
        read_repo_file("packages/agent/src/domains/agent/loop/turn_runner/mod.rs"),
        read_repo_file("packages/agent/src/domains/agent/loop/profile_runtime.rs"),
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

    let soul = read_repo_file("packages/agent/src/domains/agent/context/soul.rs");
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

    let run_context = read_repo_file("packages/agent/src/domains/agent/loop/types.rs");
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
            "packages/agent/src/domains/agent/loop/orchestrator/agent_factory.rs",
        ),
        (
            "tron agent",
            "packages/agent/src/domains/agent/loop/tron_agent/mod.rs",
        ),
        (
            "turn runner",
            "packages/agent/src/domains/agent/loop/turn_runner/mod.rs",
        ),
        (
            "capability phase",
            "packages/agent/src/domains/agent/loop/turn_runner/capability_invocations/mod.rs",
        ),
        (
            "capability executor",
            "packages/agent/src/domains/agent/loop/capability_invocation_executor/mod.rs",
        ),
        (
            "compaction handler",
            "packages/agent/src/domains/agent/loop/compaction_handler/mod.rs",
        ),
        (
            "context manager",
            "packages/agent/src/domains/agent/context/context_manager/mod.rs",
        ),
        (
            "context manager types",
            "packages/agent/src/domains/agent/context/types.rs",
        ),
        (
            "primitive surface resolver",
            "packages/agent/src/domains/agent/loop/primitive_surface.rs",
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
            "packages/agent/src/domains/agent/loop/capability_invocation_executor/mod.rs",
        ),
        (
            "capability invocation phase",
            "packages/agent/src/domains/agent/loop/turn_runner/capability_invocations/mod.rs",
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
        .filter(|(label, _)| *label != "capability invocation executor")
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
        ("server startup", "packages/agent/src/app/bootstrap/mod.rs"),
        (
            "server runtime context",
            "packages/agent/src/shared/server/context.rs",
        ),
        (
            "domain registration context",
            "packages/agent/src/domains/registration/worker.rs",
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
