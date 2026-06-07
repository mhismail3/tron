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

#[test]
fn primitive_engine_teardown_plan_stays_formalized() {
    let scorecard = read_repo_file("packages/agent/docs/primitive-engine-teardown-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/primitive-engine-teardown-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# Primitive Engine Teardown Scorecard",
        "Current score: **37/100**",
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
        "| PET-4 | Soul and agent-owned state workspace | 10 | pending |",
        "| PET-5 | Session, event, ledger, and resource collapse | 8 | pending |",
        "| PET-6 | Rules, skills, hooks, guardrails, approvals, and policy deletion | 8 | pending |",
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
        "Current score: **37/100**",
        "Status: **active execution artifact**",
        "New teardown branch: `codex/primitive-engine-teardown`",
        "Compatibility assumption: none.",
        "| PET-0 | passed_after_fix |",
        "| PET-1 | passed_after_fix |",
        "| PET-2 | passed_after_fix |",
        "| PET-3 | passed_after_fix |",
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
