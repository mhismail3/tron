//! Static gates for the hyper modular agent architecture planning scorecard.
//!
//! This test stays separate from `threat_model_invariants.rs` so the broad
//! north-star planning guard does not grow the already-budgeted cross-cutting
//! invariant file.

use std::path::PathBuf;

#[test]
fn hyper_modular_architecture_plan_stays_formalized() {
    let repo_root = repo_root();
    let scorecard_path =
        repo_root.join("packages/agent/docs/hyper-modular-agent-architecture-scorecard.md");
    let portfolio_path =
        repo_root.join("packages/agent/docs/hyper-modular-agent-harness-execution-scorecards.md");
    let scorecard = std::fs::read_to_string(&scorecard_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", scorecard_path.display()));
    let portfolio = std::fs::read_to_string(&portfolio_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", portfolio_path.display()));
    let readme = std::fs::read_to_string(repo_root.join("README.md")).expect("read README.md");
    let primitive_surface = std::fs::read_to_string(repo_root.join(
        "packages/agent/src/domains/capability_support/implementations/primitive_surface.rs",
    ))
    .expect("read primitive_surface.rs");
    let capability_contract = std::fs::read_to_string(
        repo_root.join("packages/agent/src/domains/capability/contract.rs"),
    )
    .expect("read capability contract");
    let sandbox_contract =
        std::fs::read_to_string(repo_root.join("packages/agent/src/domains/sandbox/contract.rs"))
            .expect("read sandbox contract");
    let readme_harness_section = readme
        .split("Agents do not need to inspect Tron source to create a local worker.")
        .nth(1)
        .expect("README must document worker protocol guide loop");

    assert!(
        readme.contains("packages/agent/docs/hyper-modular-agent-architecture-scorecard.md")
            && readme.contains(
                "completed planning scorecard for the iii-informed hyper modular agent harness"
            )
            && readme.contains(
                "packages/agent/docs/hyper-modular-agent-harness-execution-scorecards.md"
            )
            && readme.contains("fresh execution scorecard portfolio"),
        "README living-doc map must link the hyper modular planning and execution scorecards"
    );

    for required in [
        "Current score: **100/100**",
        "Status: **completed planning artifact**",
        "Implementation execution status: **not started by this planning scorecard**",
        "/Users/moose/.codex/attachments/0af3ea78-c386-4055-ba8d-6e04c8eb5c49/pasted-text.txt",
        "/Users/moose/.codex/attachments/053a570d-434a-4879-bb93-1db134477b7c/pasted-text.txt",
        "`iii worker add` is the important product operation",
        "The agent and the human use the same operation to extend the same system",
        "The harness is a stack of workers, not a framework block.",
        "https://iii.dev/manifesto",
        "https://iii.dev/docs/0-10-0/primitives-and-concepts/functions-triggers-workers",
        "https://iii.dev/docs/0-10-0/primitives-and-concepts/discovery",
        "https://iii.dev/docs/0-10-0/how-to/use-functions-and-triggers",
        "https://iii.dev/docs/0-10-0/how-to/trigger-actions",
        "https://github.com/iii-hq/iii",
        "packages/agent/src/engine/mod.rs",
        "packages/agent/src/domains/capability/mod.rs",
        "packages/agent/src/domains/sandbox/mod.rs",
        "packages/ios-app/docs/architecture.md",
        "packages/agent/docs/hyper-modular-agent-harness-execution-scorecards.md",
        "## North-Star Requirements",
        "## Primitive And Plane Budget",
        "## Execution Scorecard Portfolio",
        "| HMA-B | Agent self-modifying capability lifecycle |",
        "| HMA-C | Harness knowledge and context compiler |",
        "| HMA-E | Human harness and generated UI north star |",
        "| HMA-F | Causality, safety, loops, and rollback |",
        "## Required Scenario Rows For HMA-B",
        "## Required Scenario Rows For HMA-E",
        "## Adversarial Audit",
        "| HMA-6 | Closeout verification | 10 | passed |",
        "The planning artifact is closed.",
    ] {
        assert!(
            scorecard.contains(required),
            "hyper modular planning scorecard missing required text: {required}"
        );
    }

    for forbidden in [
        "The attached pasted files available in this thread were not the iii articles.",
        "Status: **active until closeout verification**",
        "| HMA-6 | Closeout verification | 10 | pending |",
        "Then update HMA-6",
    ] {
        assert!(
            !scorecard.contains(forbidden),
            "completed planning scorecard must not retain active closeout text: {forbidden}"
        );
    }

    for required in [
        "# Hyper Modular Agent Harness Execution Scorecard Portfolio",
        "Current score: **35.25/100**",
        "Status: **running**",
        "## Source-Derived Requirements",
        "The agent and the human use the same operation to extend the same system.",
        "The harness is a composition slider, not a thin-vs-thick fork.",
        "https://iii.dev/docs/0-10-0/primitives-and-concepts/functions-triggers-workers",
        "https://iii.dev/docs/0-10-0/primitives-and-concepts/discovery",
        "https://iii.dev/docs/0-10-0/how-to/use-functions-and-triggers",
        "https://iii.dev/docs/0-10-0/how-to/trigger-actions",
        "https://iii.dev/docs/0-10-0/how-to/use-queues",
        "https://iii.dev/docs/0-10-0/advanced/protocol",
        "https://iii.dev/docs/quickstart",
        "https://iii.dev/docs/workers/managed-worker-lockfile",
        "https://github.com/iii-hq/iii",
        "## Current Tron Baseline",
        "## Primitive And Plane Budget",
        "## Operating Loop",
        "| HMH-A | Source, baseline, and primitive audit | 10 | passed |",
        "| HMH-B | Agent self-modifying capability lifecycle | 20 | passed |",
        "| HMH-C | Harness knowledge and context compiler | 15 | running |",
        "| HMH-D | Plug-and-play module/package lifecycle | 15 | pending |",
        "| HMH-E | Human harness and generated UI | 15 | pending |",
        "| HMH-F | Causality, safety, loops, and rollback | 15 | pending |",
        "| HMH-G | Final adversarial closeout and absence gates | 10 | pending |",
        "| HMH-A1 | Attachment synthesis is first-class source | 20 | passed |",
        "| HMH-A2 | Public iii facts verified | 15 | passed |",
        "| HMH-A3 | Current Tron substrate map is evidence-backed | 25 | passed |",
        "| HMH-A4 | Primitive/plane budget accepted | 20 | passed |",
        "| HMH-A5 | Prior scorecards treated as prerequisites only | 10 | passed |",
        "| HMH-A6 | Fresh execution portfolio linked and guarded | 10 | passed |",
        "HMH-A closeout evidence, 2026-06-02:",
        "## HMH-B Scorecard: Agent Self-Modifying Capability Lifecycle",
        "| HMH-B1 | Model is taught the lifecycle | 10 | passed_after_fix |",
        "HMH-B1 evidence, 2026-06-02:",
        "The fix keeps guidance in the existing model-facing surfaces",
        "| HMH-B2 | Worker guide is sufficient | 10 | passed_after_fix |",
        "HMH-B2 evidence, 2026-06-02:",
        "as the profile-backed agent actor while server-owned execution policy scopes",
        "| HMH-B3 | Session worker creation is scoped | 15 | passed |",
        "HMH-B3 evidence, 2026-06-02:",
        "| HMH-B4 | Live catalog update and inspection work | 10 | passed |",
        "HMH-B4 evidence, 2026-06-02:",
        "| HMH-B5 | Conformance/test evidence is resource-backed | 10 | passed_after_fix |",
        "HMH-B5 evidence, 2026-06-02:",
        "`capability::conformance_run` now creates an `evidence` resource",
        "declares a resource-backed `evidence` output contract",
        "capability_self_modifying_lifecycle_records_session_worker_conformance_evidence",
        "| HMH-B6 | Invocation uses the tiny harness | 15 | passed |",
        "HMH-B6 evidence, 2026-06-02:",
        "`observability::trace_get` with full payloads shows exactly three functions",
        "`engine::invoke`, `capability::execute`, and the generated",
        "capability_self_modifying_lifecycle_invokes_session_worker_through_execute",
        "| HMH-B7 | Promotion is governed | 10 | passed_after_fix |",
        "HMH-B7 evidence, 2026-06-02:",
        "`expectedFunctionRevision` returns `STALE_FUNCTION_REVISION`",
        "clean authority scopes",
        "capability_self_modifying_lifecycle_governs_session_worker_promotion",
        "| HMH-B8 | Cleanup and stale calls fail closed | 10 | passed |",
        "HMH-B8 evidence, 2026-06-02:",
        "`function_unregistered` change for the session",
        "`worker_unregistered` change for the volatile",
        "returns structured `needs_capability` guidance",
        "`childInvocationCreated=false`",
        "shows only `engine::invoke` and `capability::execute`",
        "capability_self_modifying_lifecycle_cleans_up_session_worker_and_stale_calls_fail_closed",
        "local_external_worker_durable_disconnect_marks_functions_unhealthy",
        "| HMH-B9 | Agent explains the evidence | 10 | passed |",
        "HMH-B9 evidence, 2026-06-02:",
        "A deterministic provider first emits a model `execute` invocation targeting",
        "On the second provider",
        "payload includes the current function id, worker id, plugin id",
        "`executeInvocationId`",
        "`childInvocationIds`",
        "governed promotion with `expectedFunctionRevision`",
        "cleanup through `sandbox::stop_spawned_worker` or",
        "contains no README-only explanation",
        "capability_self_modifying_lifecycle_explains_session_worker_evidence",
        "Open loops after HMH-B1/HMH-B2/HMH-B3/HMH-B4/HMH-B5/HMH-B6/HMH-B7/HMH-B8/HMH-B9:",
        "HMH-B is closed.",
        "## HMH-C Scorecard: Harness Knowledge And Context Compiler",
        "| HMH-C1 | Primer contains the north-star recipe | 20 | passed_after_fix |",
        "HMH-C1 evidence, 2026-06-02:",
        "initially failed after the C1 test was strengthened to require generated",
        "`ui::surface_for_target`",
        "`ui::inspect_surface`",
        "`ui::submit_action`",
        "stored surface/version/action ids",
        "The fix keeps the recipe in the fixed `capabilities.primer` header",
        "README's worker-protocol section now matches the primer",
        "Open loops after HMH-C1:",
        "| HMH-C2 | Context budget remains bounded | 15 | passed_after_fix |",
        "HMH-C2 evidence, 2026-06-02:",
        "initially failed with a `2633` estimated-token primer",
        "profile `2600` token budget",
        "primer over budget",
        "requires the bounded primer to preserve worker",
        "`module::register_package`",
        "worker_package",
        "source trust",
        "`module::activate`",
        "`module::run_conformance`",
        "reserves `TRUNCATION_NOTICE` before adding another rendered catalog",
        "Open loops after HMH-C1/HMH-C2:",
        "Continue with HMH-C3",
        "| HMH-C6 | Prompt surface stays tiny |",
        "## HMH-D Scorecard: Plug-And-Play Module/Package Lifecycle",
        "| HMH-D3 | Activation composes worker spawn |",
        "| HMH-D8 | No generic action escape hatch |",
        "## HMH-E Scorecard: Human Harness And Generated UI",
        "| HMH-E2 | Generated surface for new capability |",
        "| HMH-E7 | Disconnected cache is read-only |",
        "## HMH-F Scorecard: Causality, Safety, Loops, And Rollback",
        "| HMH-F2 | Approval resume preserves original context |",
        "| HMH-F7 | Restart/disconnect chaos fails closed |",
        "## HMH-G Scorecard: Final Adversarial Closeout And Absence Gates",
        "| HMH-G1 | Requirement-by-requirement completion audit |",
        "| HMH-G7 | Ledger and final status are honest |",
        "## Adversarial Audit Of This Portfolio",
        "Modular in docs, not in the agent turn.",
        "Human harness as a second engine.",
        "Scorecard closure by rhetoric.",
        "## Static Gates",
        "## Final Closeout Criteria",
        "cargo test --manifest-path packages/agent/Cargo.toml --test hyper_modular_architecture_plan_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_cleans_up_session_worker_and_stale_calls_fail_closed -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_explains_session_worker_evidence -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml primer_teaches_self_modifying_worker_lifecycle -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml capability_primer_context_stays_within_budget -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml execute_guidance_covers_self_modifying_lifecycle_errors -- --nocapture",
    ] {
        assert!(
            portfolio.contains(required),
            "hyper modular execution portfolio missing required text: {required}"
        );
    }

    for forbidden in [
        "The attached pasted files available in this thread were not the iii articles.",
        "Current score: **0/100**",
        "Status: **ready_for_execution**",
        "| HMH-A | Source, baseline, and primitive audit | 10 | pending |",
        "| HMH-B | Agent self-modifying capability lifecycle | 20 | pending |",
        "| HMH-A1 | Attachment synthesis is first-class source | 20 | pending |",
        "| HMH-B1 | Model is taught the lifecycle | 10 | pending |",
        "| HMH-B3 | Session worker creation is scoped | 15 | pending |",
        "| HMH-B4 | Live catalog update and inspection work | 10 | pending |",
        "| HMH-B5 | Conformance/test evidence is resource-backed | 10 | pending |",
        "| HMH-B6 | Invocation uses the tiny harness | 15 | pending |",
        "| HMH-B7 | Promotion is governed | 10 | pending |",
        "| HMH-B8 | Cleanup and stale calls fail closed | 10 | pending |",
        "| HMH-B9 | Agent explains the evidence | 10 | pending |",
        "| HMH-C | Harness knowledge and context compiler | 15 | pending |",
        "| HMH-C1 | Primer contains the north-star recipe | 20 | pending |",
        "| HMH-C2 | Context budget remains bounded | 15 | pending |",
        "Open loops after HMH-B1/HMH-B2/HMH-B3/HMH-B4/HMH-B5/HMH-B6/HMH-B7:",
        "Open loops after HMH-B1/HMH-B2/HMH-B3/HMH-B4/HMH-B5/HMH-B6/HMH-B7/HMH-B8:",
        "Continue with HMH-B8: prove cleanup unregisters or marks stale session-worker",
        "Continue with HMH-B9: prove the agent can explain live",
        "Continue with HMH-C1: prove the compact",
        "Continue with HMH-C2: prove the context",
        "Current score: **19/100**",
        "Current score: **21/100**",
        "Current score: **24/100**",
        "Current score: **26/100**",
        "Current score: **28/100**",
        "Current score: **30/100**",
        "Current score: **33/100**",
        "Current score: **100/100**",
        "Status: **completed**",
    ] {
        assert!(
            !portfolio.contains(forbidden),
            "execution portfolio must not claim completion or preserve forbidden plane text: {forbidden}"
        );
    }

    assert!(
        primitive_surface.contains("provider_surface_contains_only_capability_primitives")
            && primitive_surface
                .contains("assert_eq!(surface.all_model_capability_ids, [\"execute\"]);")
            && primitive_surface
                .contains("only the `capability` worker's `execute` orchestrator is exposed"),
        "provider surface must keep a concrete guard against prompt-expanded tool catalogs"
    );
    assert!(
        capability_contract.contains("fn only_execute_has_model_metadata()")
            && capability_contract
                .contains("assert!(model_metadata(SEARCH_FUNCTION_ID).is_null());")
            && capability_contract
                .contains("assert!(!model_metadata(EXECUTE_FUNCTION_ID).is_null());")
            && capability_contract.contains("admin_write_resource_backed_contract")
            && capability_contract.contains("CONFORMANCE_RUN_FUNCTION_ID")
            && capability_contract.contains("[\"evidence\"]"),
        "capability contract must guard execute as the only model metadata owner and conformance evidence as resource-backed"
    );
    assert!(
        sandbox_contract.contains("worker::spawn")
            && !sandbox_contract.contains("sandbox::spawn_worker"),
        "worker creation must remain canonical worker::spawn, not an alternate sandbox public API"
    );
    assert!(
        readme_harness_section.contains("Session visibility is the default")
            && readme_harness_section.contains("workspace/system")
            && readme_harness_section.contains("`engine::promote`")
            && readme_harness_section.contains("`ui::surface_for_target`")
            && readme_harness_section.contains("`ui::inspect_surface`")
            && readme_harness_section.contains("`ui::submit_action`")
            && readme_harness_section.contains("surface/version/action ids"),
        "README must document session-worker default visibility, generated UI handoff, and governed promotion"
    );
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("packages/agent parent")
        .parent()
        .expect("repo root")
        .to_path_buf()
}
