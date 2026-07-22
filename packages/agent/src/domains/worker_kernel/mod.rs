//! Trusted-local persistent worker kernel.
//!
//! This domain is the executable self-extension path. A complete bundle is
//! staged, dependency-locked, smoke-tested, atomically versioned, activated,
//! and projected as a direct typed model tool by one `worker_upsert` call.
//! Acquisition seals dependency checksums before hashing; bounded UTF-8 source
//! imports reject symlinks and special files. Filesystem bundles are canonical,
//! while SQLite owns rebuildable indexes and durable operational evidence.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Primitive identity plus request, response, and worker-bundle schemas |
//! | `handlers` | Model/client operation bindings |
//! | `host` | Bounded trusted-local filesystem, process, and network primitives |
//! | `persistence` | Canonical bundles, index reconstruction, and durable operational ledgers |
//! | `core_proposals` | Temporary isolated Git worktrees, durable tested commits, bounded evidence, and recorded conversational approval |
//! | `process` | Bounded child-process I/O and isolated process-tree lifecycle shared by tools and runners |
//! | `retrieval` | Shared deterministic worker ranking and semantic-router recovery |
//! | `runtime` | Activation, runners, lifecycle, dispatch, dynamic tools, semantic engine hooks, supervision, and primitive session-metadata actuation |
//! | `surface` | Canonical fixed/dynamic model-tool selection and provider-neutral introspection evidence |
//! | `types` | Worker bundle and durable runtime DTOs |
//!
//! ## Entry Points
//!
//! [`registration`] composes fixed operations and the durable runtime.
//! [`resolve_tool_surface`] builds each provider turn's exact tool set. State
//! retirement and offline restore are re-exported from `persistence` for
//! bootstrap and CLI callers.
//!
//! ## Dependency Direction
//!
//! Agent turns and authenticated transport call this domain; the generic engine
//! and client presentation layers never depend on worker implementation types.
//!
//! ## Invariants
//!
//! Worker activation is atomic with respect to the canonical active pointer:
//! failed dependency, smoke-test, or health-check work never changes the active
//! version. Successful pre-activation evidence is sealed into the immutable
//! version before hashing. The rebuildable SQLite indexes commit before the
//! pointer; startup reconstruction therefore recovers a crash before pointer
//! publication to the prior version. A reported pointer-write failure removes
//! the unpublished candidate before rebuilding those indexes.
//! Failure while registering an already-published direct tool disables it and
//! records the failure rather than leaving an enabled but unreachable worker.
//! One typed core-primitive manifest owns the fixed provider names, groups, and
//! stable order, and every fixed primitive has a closed top-level response
//! contract. Function definitions carry one closed typed model-tool projection;
//! magic metadata keys cannot silently add tools, routing modes, or test-only
//! ranking inputs. Resolved provider entries are callable by construction;
//! availability is decided once during catalog projection rather than copied
//! into a second boolean. Every provider request records the exact catalog revision,
//! function revisions, selected worker versions, reasons, and surface hash.
//! Provider calls pin the advertised function revision and immutable worker
//! version; catalog preparation rejects drift and lets the next internal turn
//! resolve a fresh surface. Session discovery promotions live in durable scoped
//! engine state, are recency ordered and version bound, and survive restart.
//! Worker identity, storage, ranking, and availability are profile-global;
//! workspace is invocation context only and cannot hide or reveal tools.
//! Both stored promotions and the final dynamic provider surface have hard
//! bounds, so repeated discovery cannot grow an unbounded tool request or
//! revive a retired worker id at a different version.
//! Semantic engine hooks are immutable bundle declarations activated by the
//! same atomic upsert and version pointer as the worker tool. They are not a
//! separate installer, binding, grant, or selection plane. Each hook has one
//! fixed typed contract, selects the newest declaring worker when that worker
//! is healthy and enabled, and uses the ordinary durable dispatcher. An older
//! implementation never silently replaces a failed or disabled current owner.
//! Inbox policy sees only bounded redacted previews. Its selected ids are
//! validated against the candidate set and claimed all-or-none before its
//! narrative enters provider context, so concurrent sessions cannot inject a
//! narrative for observations they did not consume.
//! Model-facing run and inbox reads are compact and bounded by default. An
//! explicit operator detail request expands at most twenty records and still
//! caps each retained input, output, or result, preventing durable history from
//! becoming an unbounded provider-context or transport payload.
//! The Engine Dashboard exposes active hook ownership. `context_summary`,
//! `inbox_context`, and `worker_relevance` are production hooks. Each retains a
//! narrow deterministic recovery path in the kernel so compaction, background
//! context, and tool projection cannot depend recursively on their own policy
//! worker.
//! The authenticated `engine::surface_snapshot` read returns the selected
//! surface revision/hash/counts, every published worker's projection status,
//! the complete fixed-tool inventory, and canonical engine worker summaries;
//! exact provider contracts are not duplicated into the client response. It is
//! not itself model vocabulary and reports executable runtime facts rather than
//! a separately maintained description of the source tree.
//! Fixed inventory is always model-callable. Worker-first operation is the
//! engine architecture rather than an editable mode or secondary lifecycle.
//! Explicit discovery and automatic projection use one worker-owned relevance
//! hook when installed. Its bounded candidate contract carries canonical worker
//! metadata and operational evidence without exposing provider internals. The
//! local recovery scorer uses exact field-weighted tokens and bounded adjacent
//! phrases, so conversation framing and substring collisions cannot manufacture
//! relevance when the hook is absent, unhealthy, or executing itself. Mutable
//! run/health evidence is a rebuildable engine-state overlay, not
//! function-contract text; successful work therefore cannot churn catalog
//! revisions. Fixed invocation supports durable enqueue plus bounded await so
//! parallel workers do not monopolize provider calls.
//! Every canonical load verifies both `content.sha256` and the full version
//! tree against its directory name. File and symlink targets participate in
//! dependency and version hashes. Command, agent, and resident runners execute
//! from disposable copies under `internal/run/`; worker writes therefore never
//! mutate the canonical version, and an out-of-band mutation disables routing
//! as an integrity failure before code executes.
//! Local worker execution is deliberately not tool-authorized. Named
//! credential values are injected only at runtime; known vault and provider-key
//! values are rejected from candidate bundles and invocation inputs, then
//! redacted from outputs and errors so they never enter manifests, operational
//! records, events, or logs.
//! Every claimed delivery creates a numbered attempt. Interrupted attempts are
//! terminalized before their invocation is requeued, making at-least-once
//! redelivery and causal-loop suppression directly inspectable. Engine events
//! overlay payload keys declared by the input schema onto configured defaults;
//! no framework envelope is injected. A projected event outside the typed
//! schema is a terminal worker failure, not an endlessly retried delivery. A
//! persistence failure retains the cursor for retry.
//! Lazy resident processes remain supervised between invocations: an exit or three
//! consecutive health-check failures disables routing and creates a durable
//! high-visibility inbox result. System inbox failures without invocation rows
//! remain eligible for one-time attachment to the next relevant session.
//! Trusted-local host operations are unrestricted by policy but bounded for
//! reliability. File reads, directory listings, searches, writes, and edits run
//! off the async executor. Writes and exact occurrence-checked edits stage,
//! sync, recheck prior state, rename in the target directory, and sync the
//! directory before reporting success. Text search defaults to five seconds and
//! 20,000 walked entries, skips hidden/heavy child trees unless requested, and
//! reports every truncation cause. An agent abort or server shutdown therefore
//! cannot be held indefinitely by a home-directory search.
//! The fixed `session_set_title` operation owns only durable mutation and live
//! projection. Title generation, eligibility, prompting, and normalization are
//! worker policy and do not run implicitly in the agent prompt lifecycle.
//! Executable child I/O is concurrent and bounded. Unix process groups make
//! cancellation kill descendants; trusted-local `PATH` restores conventional
//! host tools hidden by service launchers. Details belong to `process`.
//! Mutation schemas reject empty or inapplicable checksum preconditions before
//! execution so provider contracts match compare-and-swap runtime behavior.
//! Command, smoke-test, and health-check working directories are always the
//! bundle's `files/` directory. A dependency named `N` is acquired beneath
//! `../dependencies/N`; its optional install command runs within that directory
//! before validation commands, making the authoring layout deterministic.
//! Lifecycle events and audit retain reliability evidence while redacting
//! credential fields and recognizable secrets. One-time webhook credentials
//! exist raw only in the active provider turn that requested them.
//! Webhook bodies are ordinary typed input: trigger configuration supplies
//! defaults, request keys override them, and no engine wrapper is injected.
//! Unseen inbox attachment uses an internal runtime identity with session/trace
//! provenance; it never requires or fabricates an agent grant.
//! Core proposal worktrees exist only while a patch is authored and tested.
//! Successful creation removes the worktree and retains the branch/commit plus
//! proposal evidence, so idle proposals do not duplicate an entire source tree.
//! An agent-runner drop guard aborts its child on timeout, stop, disable, or
//! shutdown. Causal depth survives the child hop, and pre-admission event
//! subscription preserves even an immediate provider failure's terminal error.
//! Core proposal diffs retain exact text/newlines; purge is irreversible while retirement remains recoverable.
//! Core proposal approval rejects negated or ambiguous messages. A failed
//! approved cherry-pick is aborted and verified back at its original commit
//! before the proposal remains in the tested state. Failed proposal creation
//! removes its worktree, branch, and proposal directory; no inert proposal
//! shell is retained.
//!
//! ## Test Ownership
//!
//! Unit tests live beside each concern; cross-domain replay,
//! provider-tool, transport, and client proofs live under `packages/agent/tests`.

use std::sync::Arc;

use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};

mod contract;
mod core_proposals;
mod handlers;
mod host;
mod persistence;
mod process;
mod retrieval;
mod runtime;
mod surface;
#[cfg(test)]
mod tests;
mod types;

pub(crate) use contract::{CONTEXT_SUMMARY_FUNCTION, WORKER_RELEVANCE_FUNCTION};

pub(crate) use runtime::WorkerRuntime;
#[cfg(test)]
pub(crate) use surface::{AvailableWorkerToolSnapshot, SurfaceToolSnapshot};
pub(crate) use surface::{EngineSurfaceSnapshot, promote_worker_for_session, resolve_tool_surface};

pub(crate) struct Registration {
    pub(crate) functions: Vec<DomainFunctionRegistration>,
    pub(crate) engine_functions: Vec<DomainFunctionRegistration>,
    pub(crate) runtime: Arc<WorkerRuntime>,
}

pub(crate) fn registration(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Registration> {
    let store = persistence::WorkerStore::open(deps.settings_runtime.home().to_path_buf())
        .map_err(crate::engine::EngineError::HandlerFailed)?;
    let runtime = WorkerRuntime::new(
        store,
        deps.engine_host.clone(),
        deps.orchestrator.clone(),
        deps.session_manager.clone(),
        deps.event_store.clone(),
        deps.settings_runtime.clone(),
    )
    .map_err(crate::engine::EngineError::HandlerFailed)?;
    let mut functions = handlers::bind_functions(
        contract::function_definitions()?,
        handlers::Deps {
            runtime: Arc::clone(&runtime),
        },
    )?;
    for registration in &mut functions {
        if let Some(descriptor) =
            contract::core_primitive_for_function(registration.definition.id.as_str())
        {
            registration.definition.model_tool = Some(crate::engine::ModelToolContract {
                name: descriptor.model_name.to_owned(),
                callable: true,
                order: Some(descriptor.order),
                group: Some(descriptor.group.as_str().to_owned()),
                worker: None,
            });
        }
    }
    let (engine_functions, functions): (Vec<_>, Vec<_>) = functions
        .into_iter()
        .partition(|registration| registration.definition.id.namespace() == "engine");
    Ok(Registration {
        functions,
        engine_functions,
        runtime,
    })
}
