//! Context-guide rendering for worker orchestration.
//!
//! Guide policy and rendering live here so catalog persistence and search
//! indexing do not own model-facing documentation text. The fixed header stays
//! compact so tight budgets still include actual worker ability entries; longer
//! product recipes are appended only when they fit.

use serde::{Deserialize, Serialize};

use super::index::trust_rank;
use super::{AgentCapabilityRecipeDisplay, CapabilityRegistryEntry, CapabilityRegistrySnapshot};

const TRUNCATION_NOTICE: &str = "- Additional worker abilities are available through the same `execute` Work router; provide intent or a target hint and the engine resolves the catalog entry.\n";

const COMPACT_EXECUTE_ROUTING_GUIDANCE: &str = "Use `execute` as the Work router for worker abilities; target the real worker ability, not approval::request. Delegate non-trivial work to workers and gather results.\n\n";

const EXECUTE_ROUTING_GUIDANCE: &str = "Use `execute` as the Work router for worker abilities. Use known worker ability targets directly; for unknown work start with intent. For non-trivial work, act as the orchestrator: delegate focused investigation, implementation, or verification slices to workers with `agent::spawn_subagent` or spawned helper abilities, spawn fan-out workers before collecting results, then gather with `agent::subagent_status`, `agent::subagent_result`, or the helper's returned artifacts. Canonical shape is target plus arguments; execute can correct flattened target args. Prefer filesystem for repo/code evidence. Target the real work capability; do not target approval::request directly. Approval-gated write commands use process::run with {\"executionMode\":\"sandbox_materialized\",\"expectedOutputs\":[{\"path\":\"result.txt\"}]}, not filesystem::write_file. Each path must be relative and the command must write the same declared sandbox path. Worktree discard uses worktree::discard_files with repo-relative paths only and pauses for user approval. Freshness and approval happen inside execute.\n\n";

const SELF_EXTENSION_GUIDANCE: &str = "To extend autonomous Work: target `self_extension::grant_workspace_autonomy` with absolute workspacePath; omit workspaceId for the current workspace unless a prior result gave the exact id. Approval returns `Safe in this workspace`. Workspace-visible helper work passes `workspaceAutonomyGrantId` and the returned workspaceId to `worker::spawn`; if resourceSelectors is omitted, spawn uses `workspace:<workspaceId>`. Use that returned workspaceId as execute's top-level workspaceId for `catalog::watch_snapshot`, `capability::inspect`, and helper calls. Then call `worker::protocol_guide`, author the worker, `worker::spawn`, prove catalog visibility, run conformance or test evidence, and invoke through `execute`. For Worker Packs: `module::register_package` over worker_package, inspect, source trust, configure, `module::activate`, `module::run_conformance`, upgrade, rollback, disable, revoke, or remove. Use generated `ui_surface` as a worker artifact: `ui::surface_for_target`, `ui::inspect_surface`, `ui::submit_action` with stored surface/version/action ids. Use `engine::promote` for governed promotion; clean sandbox-spawned helpers with `sandbox::stop_spawned_worker`; use `worker::disconnect` only for raw volatile protocol cleanup; discard helper files with `worktree::discard_files` and repository-relative paths only. Report Work status, outcomes, blockers, and cleanup state in chat. Keep grant ids, trace ids, resource refs, catalog revision, child invocation ids, function ids, and raw schemas in Audit.\n\n";

const CORE_CONTEXT_CAPABILITIES: &[&str] = &[
    "capability::execute",
    "filesystem::list_dir",
    "filesystem::read_file",
    "filesystem::write_file",
    "filesystem::edit_file",
    "filesystem::find",
    "filesystem::glob",
    "filesystem::search_text",
    "filesystem::diff",
    "filesystem::apply_patch",
    "process::run",
    "web::search",
    "web::fetch",
    "notifications::send",
    "agent::ask_user",
    "agent::status",
    "agent::submit_answers",
    "agent::spawn_subagent",
    "agent::subagent_status",
    "agent::subagent_result",
    "agent::cancel_subagent",
    "job::wait",
    "job::stream_output",
    "self_extension::grant_workspace_autonomy",
    "worker::spawn",
    "sandbox::list_spawned_workers",
    "sandbox::stop_spawned_worker",
    "worker::protocol_guide",
];

/// Profile-controlled Worker Guide policy.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(crate) struct CapabilityContextPrimerPolicy {
    pub(crate) enabled: bool,
    pub(crate) mode: String,
    pub(crate) max_tokens: usize,
    pub(crate) include_examples: bool,
    pub(crate) include_compact_schemas: bool,
}

impl Default for CapabilityContextPrimerPolicy {
    fn default() -> Self {
        Self {
            enabled: true,
            mode: "coreFirstParty".to_owned(),
            max_tokens: 2600,
            include_examples: true,
            include_compact_schemas: true,
        }
    }
}

impl CapabilityRegistrySnapshot {
    pub(crate) fn visible_primer_entries(
        &self,
        policy: &CapabilityContextPrimerPolicy,
    ) -> Vec<CapabilityRegistryEntry> {
        if !policy.enabled {
            return Vec::new();
        }
        let all_visible = policy.mode == "allVisibleCompact";
        let mut entries = self
            .entries
            .iter()
            .filter(|entry| {
                all_visible
                    || entry.context_primer_level == "core"
                    || CORE_CONTEXT_CAPABILITIES.contains(&entry.function_id.as_str())
            })
            .cloned()
            .collect::<Vec<_>>();
        entries.sort_by(|a, b| {
            primer_rank(a)
                .cmp(&primer_rank(b))
                .then_with(|| a.function_id.cmp(&b.function_id))
        });
        entries
    }
}

pub(super) fn is_core_context_capability(function_id: &str) -> bool {
    CORE_CONTEXT_CAPABILITIES.contains(&function_id)
}

pub(crate) fn render_capability_primer(
    snapshot: &CapabilityRegistrySnapshot,
    policy: &CapabilityContextPrimerPolicy,
) -> Option<String> {
    let mut entries = snapshot.visible_primer_entries(policy);
    if entries.is_empty() {
        return None;
    }
    let mut out = String::from("# Worker Guide\n\n");
    out.push_str(&format!(
        "Catalog revision: {}.\n\n",
        snapshot.catalog_revision
    ));
    if estimated_tokens(out.len() + EXECUTE_ROUTING_GUIDANCE.len() + TRUNCATION_NOTICE.len())
        <= policy.max_tokens
    {
        out.push_str(EXECUTE_ROUTING_GUIDANCE);
    } else {
        out.push_str(COMPACT_EXECUTE_ROUTING_GUIDANCE);
    }
    if has_self_extension_entries(&entries)
        && estimated_tokens(out.len() + SELF_EXTENSION_GUIDANCE.len() + TRUNCATION_NOTICE.len())
            <= policy.max_tokens
    {
        out.push_str(SELF_EXTENSION_GUIDANCE);
    }
    let total_entries = entries.len();
    for (index, entry) in entries.drain(..).enumerate() {
        let recipe = entry.agent_recipe();
        let display = AgentCapabilityRecipeDisplay::new(&recipe);
        let mut line = format!(
            "- `{}` — {}. Use when: {}",
            recipe.contract_id, recipe.display_name, recipe.use_when
        );
        if policy.include_compact_schemas {
            if !recipe.required_payload.is_empty() {
                line.push_str(&format!(
                    " Required arguments: {}",
                    display.required_arguments
                ));
            }
            if let Some(optional) = display.optional_arguments_limited(6) {
                line.push_str(&format!(" Optional: {optional}"));
            }
        }
        if policy.include_examples
            && let Some(example) = &display.execute_template_json
        {
            line.push_str(&format!(" Execute: {example}"));
            if let Some(example) = &display.risky_direct_example_json {
                line.push_str(&format!(" Risky execute: {example}"));
            }
        }
        if let Some(guidance) = &display.primer_execution_guidance {
            line.push_str(guidance);
        }
        line.push('\n');
        let has_more_entries = index + 1 < total_entries;
        let reserved_notice_len = if has_more_entries {
            TRUNCATION_NOTICE.len()
        } else {
            0
        };
        if estimated_tokens(out.len() + line.len() + reserved_notice_len) > policy.max_tokens {
            if estimated_tokens(out.len() + TRUNCATION_NOTICE.len()) <= policy.max_tokens {
                out.push_str(TRUNCATION_NOTICE);
            }
            break;
        }
        out.push_str(&line);
    }
    Some(out)
}

fn primer_rank(entry: &CapabilityRegistryEntry) -> (u8, u8, u8) {
    let primitive = if entry.is_capability_primitive() {
        0
    } else {
        1
    };
    let core = if entry.context_primer_level == "core" {
        0
    } else {
        1
    };
    (primitive, core, trust_rank(&entry.trust_tier))
}

fn has_self_extension_entries(entries: &[CapabilityRegistryEntry]) -> bool {
    entries.iter().any(|entry| {
        matches!(
            entry.function_id.as_str(),
            "self_extension::grant_workspace_autonomy"
                | "worker::protocol_guide"
                | "worker::spawn"
                | "catalog::watch_snapshot"
                | "capability::inspect"
                | "capability::conformance_run"
                | "module::register_package"
                | "module::activate"
                | "module::run_conformance"
                | "ui::surface_for_target"
                | "ui::inspect_surface"
                | "ui::submit_action"
                | "worker::disconnect"
        )
    })
}

fn estimated_tokens(chars: usize) -> usize {
    chars / 4
}
