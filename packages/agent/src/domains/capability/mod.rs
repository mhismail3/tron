//! capability domain worker.
//!
//! This module owns the collapsed model-facing harness. It does not implement
//! filesystem, web, MCP, shell, UI, or app behavior itself; it exposes stable
//! an `execute` primitive over the live engine catalog. The runnable catalog
//! remains the execution source of truth, while this domain maintains the
//! durable capability registry/index/audit layer in the engine ledger database.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Canonical `capability::*` function contracts and model metadata |
//! | `deps` | Narrow dependency bundle for catalog, registry-store, embedding, and invocation access |
//! | `embeddings` | Embedded first-party ONNX/tokenizer provider for offline local search |
//! | `handlers` | Declarative operation bindings for model primitives plus capability admin/console functions |
//! | `operations` | Operator/internal capability operations; `operations/execute.rs` owns model-facing orchestration, `operations/run.rs` owns child execution/approval projection, and `operations/{search,inspect,audit}.rs` own operator discovery, inspection, and audit query boundaries |
//! | `registry` | Durable catalog projection, plugin manifests, binding decisions, search index, inspection handles, pause/run records, program runs, and primer rendering; recipes live in `registry/recipes.rs` |
//! | `types` | Typed contract, implementation, binding, inspection, execution, lifecycle, and program-run records |
//!
//! # INVARIANT: the model-facing surface is tiny
//!
//! Provider integrations should only expose the `execute` primitive. All other
//! behavior must remain discoverable/executable as worker-owned catalog entries
//! rather than prompt-expanded hardcoded capabilities. Admin functions such as
//! `capability::search`, `capability::inspect`, `capability::status`,
//! `capability::plugin_list`, and `capability::policy_validate` are normal
//! catalog functions for operator clients and are never marked with
//! model-facing capability metadata. Admin mutations are system-idempotent
//! because the Engine Console is an operator surface, not a session transcript
//! participant.
//! `execute` owns freshness preparation for mutating or elevated-risk
//! execution: it resolves the target, records a fresh inspection handle when
//! needed, validates target schema/policy/idempotency, and then routes through
//! the same approval and child invocation path. Payload-sensitive first-party
//! contracts may lower the effective risk before this check, as `process::run`
//! does for classifier-approved read/check commands, but the same payload
//! classifier must also drive approval so the fast path cannot bypass safety.
//! Low-risk user-visible notifications are another explicit direct path:
//! `notifications::send` is still idempotent and audited, but it is primed and
//! executable without a separate inspect round trip so notification parity does
//! not depend on shelling out to OS notification commands.
//! Target-owned payload schema, policy, and idempotency preflight rejections
//! are surfaced as structured `CapabilityResult { is_error: true }` values with
//! no child invocation, approval, or durable output. Capability execution should
//! fail the engine invocation only for wrapper-level authority/availability
//! problems or unexpected child execution failures, not for normal target
//! contract rejections that the model must report back to the operator.
//! Approval-required executions resume through `approval::resolve`, but the
//! original `capability::execute` result must still project the executed
//! approval state and resumed child invocation id. The model should not need to
//! query approval internals to answer whether approval happened or which target
//! invocation produced the output. The agent turn runner also projects the
//! bounded execute observation metadata into the model-visible tool result
//! text, because provider APIs only feed the LLM result content, not the
//! engine-only `details` object used by UI and audit surfaces. That projection
//! includes correction guidance such as missing argument paths so the model can
//! repair a call without guessing at wrapper-vs-target payload shape.
//! Intent-only resolution fails closed: if the best match has no lexical/name
//! anchor, no supplied argument shape, and only a weak semantic score, execute
//! returns `needs_capability` instead of presenting unrelated low-confidence
//! candidates as an actionable selection.
//! Target-shaped arguments are also a positive resolution signal. When a model
//! omits `target` but supplies arguments that validate against a live
//! capability schema, the resolver may promote that capability from the full
//! catalog before applying ambiguity checks. This keeps `execute` usable when
//! semantic ranking is noisy while still failing closed for empty or
//! non-matching argument sets.
//! Interactive and async capabilities are represented by durable pause/run
//! records, not by special runner branches. A capability that needs approval,
//! user input, streaming, or background execution returns lifecycle metadata;
//! the engine persists that state, emits `capability.pause.*` or
//! `capability.run.status`, and resumes/cancels only through authority-checked
//! capability functions.
//!
//! # INVARIANT: search is local and explicit about degradation
//!
//! The default search policy prefers the binary-embedded first-party embedding
//! model plus the persistent `sqlite-vec` index, but an indexing vector table
//! must not make agent discovery fail. Search returns lexical hits with an
//! explicit degraded index status while vectors warm in the background. Query
//! handling must not re-embed the whole catalog: registry documents carry text
//! hashes, unchanged catalog revisions skip metadata resync, changed documents
//! are warmed incrementally, and a search request embeds only the query text
//! before fusing lexical and vector hits. Bounded batch search/inspect requests
//! share one registry snapshot for operator clients; provider models use the
//! single `execute` orchestrator, which performs resolve/prepare internally.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod embeddings;
pub(crate) mod handlers;
mod operations;
pub(crate) mod registry;
pub(crate) mod types;
pub(crate) use deps::Deps;
pub(crate) use operations::{
    audit_query_value, binding_list_value, binding_set_value, conformance_run_value, execute_value,
    implementation_set_state_value, inspect_value, plugin_inspect_value, plugin_install_value,
    plugin_list_value, plugin_promote_value, plugin_set_state_value, plugin_update_value,
    policy_get_value, policy_update_value, policy_validate_value, program_run_list_value,
    registry_snapshot_value, render_capability_primer, search_value, status_value,
};

use serde_json::Value;

use crate::domains::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    let mut registrations =
        handlers::function_registrations(contract::capabilities()?, domain_deps)?;
    for registration in &mut registrations {
        merge_metadata(
            &mut registration.definition.metadata,
            contract::model_metadata(registration.definition.id.as_str()),
        );
    }
    crate::domains::worker::domain_worker_module(
        "capability",
        contract::STREAM_TOPICS,
        registrations,
    )
}

fn merge_metadata(target: &mut Value, extra: Value) {
    if extra.is_null() {
        return;
    }
    match (target, extra) {
        (Value::Object(target), Value::Object(extra)) => {
            for (key, value) in extra {
                let _ = target.insert(key, value);
            }
        }
        (target, extra) => {
            *target = extra;
        }
    }
}
