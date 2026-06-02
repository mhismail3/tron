//! Context-primer rendering for capability discovery.
//!
//! Primer policy and rendering live here so catalog persistence and search
//! indexing do not own model-facing documentation text. The fixed header carries
//! the compact harness-customization recipe because it must survive aggressive
//! entry truncation and should not depend on README-only prose.

use serde::{Deserialize, Serialize};

use super::index::trust_rank;
use super::{AgentCapabilityRecipeDisplay, CapabilityRegistryEntry, CapabilityRegistrySnapshot};

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
    "worker::spawn",
    "sandbox::list_spawned_workers",
    "sandbox::stop_spawned_worker",
    "worker::protocol_guide",
];

/// Profile-controlled context primer policy.
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
    let mut out = String::from("# Capability Primer\n\n");
    out.push_str(&format!(
        "Catalog revision: {}.\n\n",
        snapshot.catalog_revision
    ));
    out.push_str("The model-facing primitive is `execute`. Use known targets directly; for unknown work start with intent. Canonical shape is target plus arguments; execute can correct flattened target args. Prefer filesystem for repo/code evidence. Target the real work capability; do not target approval::request directly. Approval-gated write commands use process::run with executionMode=sandbox_materialized and expectedOutputs, not filesystem::write_file; the command must write the same relative sandbox path declared in expectedOutputs. Nested declared output paths are allowed, but do not write absolute, home-relative, shell-expanded, parent-escaping, or undeclared command output paths. Freshness and approval happen inside execute. Approved execute results include idempotencyKey; reuse that exact top-level key to replay the approved command without creating another child.\n\n");
    out.push_str("To customize the harness, stay on the same `execute` primitive: call `worker::protocol_guide`, author the worker from the returned template/protocol, call `worker::spawn` with session visibility, expected function ids, and idempotency, then prove the live catalog with `catalog::watch_snapshot` or `capability::inspect`. Run conformance or test evidence before relying on the new function, invoke it through `execute`, expose human/operator controls only as generated `ui_surface` resources through `ui::surface_for_target` and `ui::inspect_surface`, and submit generated actions with `ui::submit_action` using stored surface/version/action ids instead of reconstructed client targets. Use `engine::promote` only for governed workspace/system promotion, and clean up volatile entries with `worker::disconnect` or `sandbox::stop_spawned_worker`. Report trace id, resource refs, catalog revision, child invocation ids, and cleanup state.\n\n");
    let mut rendered_entries = 0usize;
    for entry in entries.drain(..) {
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
        if rendered_entries > 0 && estimated_tokens(out.len() + line.len()) > policy.max_tokens {
            out.push_str(
                "- Additional capabilities are available through the same `execute` primitive; provide intent or a target hint and the engine resolves the catalog entry.\n",
            );
            break;
        }
        out.push_str(&line);
        rendered_entries += 1;
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

fn estimated_tokens(chars: usize) -> usize {
    chars / 4
}
