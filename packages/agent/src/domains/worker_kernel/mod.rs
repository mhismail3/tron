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
//! | `contract` | Fixed direct worker-management contracts and their adjacent contract tests |
//! | `handlers` | Model/client operation bindings |
//! | `host` | Bounded trusted-local filesystem, process, and network primitives |
//! | `persistence` | Canonical bundles, snapshot-first legacy-state retirement, index reconstruction, and durable operational ledgers |
//! | `process` | Bounded child-process I/O and isolated process-tree lifecycle shared by tools and runners |
//! | `retrieval` | Shared deterministic worker ranking and semantic-router fallback |
//! | `runtime` | Activation, runners, lifecycle, dispatch, dynamic tools, supervision, and primitive session-metadata actuation |
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
//! ranking inputs. Every provider request records the exact catalog revision,
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
//! The authenticated `engine::surface_snapshot` read returns that same
//! provider-neutral projection, every published worker's projection status,
//! the complete fixed-tool inventory, and canonical engine worker summaries;
//! it is not itself model vocabulary. The snapshot reports executable runtime
//! facts rather than a separately maintained description of the source tree.
//! Fixed inventory remains inspectable while autonomy is off and marks each
//! tool unexposed, so operator introspection never masquerades as provider
//! availability.
//! Explicit discovery and automatic projection use one deterministic weighted
//! retrieval implementation. Mutable run/health evidence is a rebuildable
//! engine-state overlay, not function-contract text; successful work therefore
//! cannot churn catalog revisions. Fixed invocation supports durable enqueue
//! plus bounded await so parallel workers do not monopolize provider calls.
//! Every canonical load verifies both `content.sha256` and the full version
//! tree against its directory name. File and symlink targets participate in
//! dependency and version hashes. Command, agent, and resident runners execute
//! from disposable copies under `internal/run/`; worker writes therefore never
//! mutate the canonical version, and an out-of-band mutation disables routing
//! as an integrity failure before code executes.
//! Local worker execution is deliberately not capability-authorized. Named
//! secret values are injected only at runtime; known vault values are rejected
//! from candidate bundles and invocation inputs, then redacted from outputs and
//! errors so they never enter manifests, operational records, events, or logs.
//! Every claimed delivery creates a numbered attempt. Interrupted attempts are
//! terminalized before their invocation is requeued, making at-least-once
//! redelivery and causal-loop suppression directly inspectable. Engine events
//! overlay payload keys declared by the input schema onto configured defaults;
//! no framework envelope is injected. A projected event outside the typed
//! schema is a terminal worker failure, not an endlessly retried delivery. A
//! persistence failure retains the cursor for retry.
//! Edits to `autonomousWorkers` hide or restore fixed/dynamic model tools,
//! cancel or resume dispatch, and stop resident services
//! without a server restart or a change to canonical worker state.
//! Authenticated clients retain read access and lifecycle/stop controls while
//! autonomy is off, but authoring and invocation remain blocked. Lazy resident
//! processes remain supervised between invocations: an exit or three
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
//! An agent-runner drop guard aborts its child on timeout, stop, disable, or
//! shutdown. Causal depth survives the child hop, and pre-admission event
//! subscription preserves even an immediate provider failure's terminal error.
//! Core proposal diffs retain exact text/newlines; purge is irreversible while retirement remains recoverable.
//! Core proposal approval rejects negated or ambiguous messages. A failed
//! approved cherry-pick is aborted and verified back at its original commit
//! before the proposal remains in the tested state.
//!
//! ## Test Ownership
//!
//! Unit tests live beside each concern; cross-domain replay, migration,
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

pub(crate) use persistence::{
    ensure_state_snapshot, list_state_snapshots, prepare_worker_state_retirement,
    restore_state_snapshot,
};
pub(crate) use runtime::WorkerRuntime;
#[cfg(test)]
pub(crate) use surface::SurfaceToolSnapshot;
pub(crate) use surface::{EngineSurfaceSnapshot, promote_worker_for_session, resolve_tool_surface};

pub(crate) struct Registration {
    pub(crate) functions: Vec<DomainFunctionRegistration>,
    pub(crate) engine_functions: Vec<DomainFunctionRegistration>,
    pub(crate) runtime: Arc<WorkerRuntime>,
}

pub(crate) fn registration(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Registration> {
    let autonomous = deps.settings_runtime.current().settings.autonomous_workers;
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
                callable: autonomous,
                order: Some(descriptor.order),
                group: Some(descriptor.group.as_str().to_owned()),
                worker: None,
            });
        }
    }
    runtime
        .configure_kernel_primitives(
            functions
                .iter()
                .filter(|registration| registration.definition.model_tool.is_some())
                .map(|registration| {
                    (
                        registration.definition.clone(),
                        Arc::downgrade(&registration.handler),
                    )
                })
                .collect(),
        )
        .map_err(crate::engine::EngineError::HandlerFailed)?;
    let (engine_functions, functions): (Vec<_>, Vec<_>) = functions
        .into_iter()
        .partition(|registration| registration.definition.id.namespace() == "engine");
    Ok(Registration {
        functions,
        engine_functions,
        runtime,
    })
}
