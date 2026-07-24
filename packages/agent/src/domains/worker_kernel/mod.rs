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
//! | `persistence` | Canonical bundles, worker-owned state, verified profile/purge archives, index reconstruction, and durable operational ledgers |
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
//! [`resolve_tool_surface`] builds each provider turn's exact tool set. The
//! offline `tron state` CLI reaches verified snapshot/list/restore entry points
//! here without opening the live engine databases.
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
//! The pinned direct-worker contract also carries runner identity into tool
//! lifecycle presentation evidence. This is immutable observation metadata,
//! never a routing or permission input, and lets clients distinguish worker
//! progress from fixed-core execution without guessing from function names.
//! Worker identity, storage, ranking, and availability are profile-global;
//! workspace is invocation context only and cannot hide or reveal tools.
//! Fixed worker creation, invocation, cancellation, lifecycle, webhook, and
//! stop-all mutations therefore deduplicate at profile scope and remain usable
//! from the profile-level Engine console without fabricating a chat session.
//! Session actuators, host mutations, and dynamically projected worker tools
//! retain causal session-scoped replay.
//! Both stored promotions and the final dynamic provider surface have hard
//! bounds, so repeated discovery cannot grow an unbounded tool request or
//! revive a retired worker id at a different version.
//! Semantic engine hooks are immutable bundle declarations activated by the
//! same atomic upsert and version pointer as the worker tool. They are not a
//! separate installer, binding, grant, or selection plane. Each hook has one
//! fixed typed contract, selects the newest declaring worker when that worker
//! is healthy and enabled, and uses the ordinary durable dispatcher. An older
//! implementation never silently replaces a failed or disabled current owner.
//! Those worker-facing hook schemas are complete in the model-visible
//! `worker_upsert` bundle contract. Context-summary narratives are accepted
//! only through an estimated 10,000 tokens and the derived 40,000 UTF-8-byte
//! storage ceiling. The accepted value is the exact value persisted at the
//! compact boundary; oversize output fails instead of being truncated into
//! divergent live and restart context. Worker authors never
//! need to inspect internal databases, auth material, server binaries, or
//! private transport shapes to discover an engine hook.
//! The same provider-neutral tool contract owns the complete worker-authoring
//! protocol for every runner and trigger. It directs agents through public
//! discovery, staged source, one atomic upsert, and public verification. A
//! missing public behavior is reported as an engine-contract gap rather than
//! inferred through database, credential, binary, lock-file, runtime-file, or
//! private-endpoint inspection.
//! Inbox policy sees only bounded redacted previews. Its selected ids are
//! validated against the candidate set and claimed all-or-none before its
//! narrative enters provider context, so concurrent sessions cannot inject a
//! narrative for observations they did not consume.
//! Model-facing run and inbox reads are compact and bounded by default. An
//! explicit operator detail request expands at most twenty records and still
//! caps each retained input, output, or result, preventing durable history from
//! becoming an unbounded provider-context or transport payload.
//! Inbox Attention is derived rather than stored: errors remain active until a
//! later successfully verified activation or rollback for that worker. A plain
//! enable toggle is not recovery evidence. Resolved errors remain immutable in
//! run and delivery audit history but are excluded from active Attention and
//! future agent-context candidates.
//! The Engine Dashboard exposes active hook ownership. `context_summary`,
//! `inbox_context`, `session_title`, and `worker_relevance` are production
//! hooks. Context summary, inbox context, and worker relevance retain narrow
//! deterministic recovery paths in the kernel so compaction, background
//! context, and tool projection cannot depend recursively on their own policy
//! worker. Session naming instead remains absent until a real worker owns it;
//! an unavailable title policy leaves the completed session untitled.
//! Synchronous hook calls have a sixty-second policy ceiling. A timed-out hook
//! is cancelled and its owner is disabled through the ordinary worker-failure
//! path rather than holding an engine lifecycle boundary for the general
//! invocation maximum.
//! Successful hook results remain in the durable inbox as already-consumed
//! audit evidence because their engine caller used them synchronously. Hook
//! failures remain pending Attention and can enter later relevant context.
//! The authenticated `engine::surface_snapshot` read returns the selected
//! surface revision/hash/counts, every published worker's projection status,
//! active engine-hook and native-client-action ownership, the complete
//! fixed-tool inventory, and canonical engine worker summaries; exact provider
//! contracts are not duplicated into the client response. It is not itself
//! model vocabulary and reports executable runtime facts rather than a
//! separately maintained description of the source tree.
//! Fixed inventory is always inspectable, while contract-declared latest-user
//! intent exposure may keep an actuator out of unrelated provider turns.
//! Worker-first operation is the engine architecture rather than an editable
//! mode or secondary lifecycle.
//! Explicit discovery and automatic projection use one worker-owned relevance
//! hook when installed. Its bounded candidate contract carries canonical worker
//! metadata and operational evidence without exposing provider internals. The
//! local recovery scorer uses exact field-weighted tokens and bounded adjacent
//! phrases, so conversation framing and substring collisions cannot manufacture
//! relevance when the hook is absent, unhealthy, or executing itself. Mutable
//! run/health evidence is a rebuildable engine-state overlay, not
//! function-contract text; successful work therefore cannot churn catalog
//! revisions. Fixed invocation and direct worker tools share one durable
//! interaction contract. Top-level agent runners begin in the background;
//! command and service versions use completed exact-version p95 evidence after
//! five samples. Unknown or predicted-fast work gets at most ten seconds in the
//! foreground, after which the same invocation is atomically detached rather
//! than cancelled or recreated. Nested worker calls remain synchronous because
//! their parent requires the typed result. `worker_await` is bounded by the
//! same interaction budget, and `worker_detach` only changes interaction
//! ownership.
//! Exact terminal worker output is validated and retained once in the durable
//! invocation ledger. Provider-facing worker results use the shared 8 KiB
//! inline-payload boundary: larger values become integrity-bound
//! `worker_result_reference` objects instead of being copied through every
//! later model turn. `worker_result_read` returns only one bounded RFC 6901
//! path/page (at most 32 KiB and twenty items), authorized to the same causal
//! trace or originating session; paired clients and system recovery may inspect
//! profile-local results. That page is present in full for the immediately
//! following provider turn, then the agent context keeps only its reference
//! and pointer coordinates; a worker explicitly re-reads it if later reasoning
//! needs the bytes. References preserve worker version, output-schema
//! digest, content digest, size, and preview. Workers decide which paths or
//! references their typed orchestration needs; the kernel never interprets
//! source, claim, citation, or report fields.
//! The fixed invocation envelope and each selected worker's nested input
//! schema are both transport admission boundaries. A nested schema or secret
//! violation is returned as an actionable invalid request before any durable
//! invocation exists; contract-loading and persistence failures remain
//! internal failures rather than being blamed on caller input.
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
//! redelivery and causal-loop suppression directly inspectable. Recovery clears
//! an interrupted agent attempt's stale child-session pointer before redelivery,
//! so the next attempt can link its own live child. Engine events
//! overlay payload keys declared by the input schema onto configured defaults;
//! no framework envelope is injected. A projected event outside the typed
//! schema is a terminal worker failure, not an endlessly retried delivery. A
//! persistence failure retains the cursor for retry.
//! Immutable bundles may choose generic `maxAgentTurns` and
//! `maxChildInvocations` ceilings. The agent runtime can only tighten its
//! global turn limit, while child admission counts canonical parent links in
//! the same SQLite transaction as insertion so a concurrent tool batch cannot
//! race beyond its parent's ceiling. Source, claim, citation, model, and repair
//! policy remain worker-owned.
//! Lazy resident processes remain supervised between invocations: an exit or three
//! consecutive health-check failures disables routing and creates a durable
//! high-visibility inbox result. System inbox failures without invocation rows
//! remain eligible for one-time attachment to the next relevant session.
//! Resident readiness is distinct from process existence. If cancellation
//! interrupts lazy startup, the next invocation resumes the health handshake
//! before sending work rather than racing a merely spawned service.
//! Trusted-local host operations are unrestricted by policy but bounded for
//! reliability. File reads, directory listings, searches, writes, and edits run
//! off the async executor. Writes and exact occurrence-checked edits stage,
//! sync, recheck prior state, rename in the target directory, and sync the
//! directory before reporting success. Text search defaults to five seconds and
//! 20,000 walked entries, skips hidden/heavy child trees unless requested, and
//! reports every truncation cause. An agent abort or server shutdown therefore
//! cannot be held indefinitely by a home-directory search.
//! The fixed `session_set_title` operation owns only explicit durable mutation
//! and live projection. Its only input is the title; the target is always the
//! current causal session, and generic latest-user intent exposure keeps it out
//! of ordinary provider turns. After each successful ordinary user exchange,
//! prompt completion freezes bounded user/assistant text and durably enqueues
//! the active `session_title` worker only while the session remains untitled.
//! It never awaits policy execution. Worker audit sessions and unsuccessful or
//! interrupted turns are ineligible. The worker can propose only `{title}`;
//! the kernel validates and compare-and-sets that result before terminal worker
//! commit, so recovery redelivery cannot overwrite an explicit concurrent
//! title. Title-policy failure remains normal worker health/inbox evidence.
//! Raw web fetches default to 128 KiB and 30 seconds, expose explicit larger
//! ceilings, and hash the retained bytes. HTML interpretation, crawling, and
//! evidence policy remain worker behavior rather than growing the primitive.
//! Worker inspection defaults to the active behavioral contract and strips
//! source-file payloads plus operational history. Operator clients can request
//! bounded full detail explicitly, preventing routine model discovery from
//! spending context on audit and source data it did not ask to review.
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
//! Pending inbox attachment uses an internal runtime identity with session/trace
//! provenance; it never requires or fabricates an agent grant.
//! Mutable worker-owned state lives outside immutable versions under
//! `workspace/worker-state/<worker-id>/`. Command and resident runners receive
//! it as `TRON_WORKER_STATE_DIR`; agent runners receive the resolved path in
//! their instruction contract, and host processes they launch inherit that
//! same binding automatically. Worker origin survives the engine-owned hidden
//! agent transport hops without granting those hops worker authority.
//! Activation checks use a temporary isolated
//! state root, so a candidate cannot mutate the active worker's data before it
//! publishes. Update, rollback, disable, and retirement preserve state.
//! Every worker schema transition first creates one verified owner-only profile
//! snapshot. Explicit purge creates and verifies a compressed archive of the
//! worker's bundles, state, and operational evidence before removing them, and
//! refuses to archive known credential material.
//! Invocation cancellation is causal and isolated: `worker_cancel`
//! terminalizes the selected queued or running invocation and its durable
//! descendants, cancels their process/request/child agents, and leaves
//! unrelated traces plus the worker enabled. Agent invocations persist their
//! child session id as run
//! evidence. Every invocation also retains the originating user session for its
//! causal trace; descendants inherit the trace root's origin rather than
//! replacing it with an internal child-agent session. Session-scoped activity
//! can therefore include direct and nested worker work without conflating the
//! user conversation with its auditable child execution. Child sessions remain
//! in the canonical session event store under a reserved worker classification:
//! ordinary chat lists exclude them, exact audit reads remain available, and no
//! second delegation database exists.
//! A provider/model tool id, direct worker parent, interaction mode, detachment
//! time, and retry link are persisted on the durable invocation. The live call
//! may additionally hold one transient correlation bridge. Command and service
//! runners publish queued, running,
//! and validation phases; agent runners additionally project bounded child-turn
//! and child-tool stage labels. The bridge is removed at terminal completion
//! and never changes durable delivery, recovery, routing, or authority.
//! Generic stage transitions are append-only evidence on that same invocation
//! ledger. `worker_runs(detail: "graph")` resolves exact invocation or
//! model-tool identity, groups session activity by causal root, and joins
//! attempts, child invocations, worker-owned agent sessions, model turns,
//! timings, tokens, cost, errors, and result previews into one bounded
//! server-ordered graph. Active descendants outrank stale parent stage evidence.
//! Historical runs without stage rows are projected conservatively from their
//! persisted timestamps and statuses. No client progress state is authoritative.
//! Presentation metadata is immutable worker-version identity. It binds a
//! worker to a versioned native/declarative experience and optional suite role;
//! unsupported or absent bindings remain operable through the generic console.
//! Core proposal worktrees exist only while a patch is authored and tested.
//! Successful creation removes the worktree and retains the branch/commit plus
//! proposal evidence, so idle proposals do not duplicate an entire source tree.
//! An agent-runner drop guard aborts its child on timeout, stop, disable, or
//! shutdown. Causal depth survives the child hop, and pre-admission event
//! subscription preserves even an immediate provider failure's terminal error.
//! The child prompt carries the immutable output schema verbatim and explains
//! that the kernel will validate it, so typed execution never asks a model to
//! satisfy a hidden contract.
//! Core proposal diffs retain exact text/newlines; purge removes live state
//! only after creating a verified recovery archive, while retirement remains
//! directly reversible from retained versions.
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

pub(crate) fn create_profile_snapshot() -> Result<persistence::ProfileSnapshot, String> {
    persistence::create_profile_snapshot(&crate::shared::foundation::paths::tron_home())
}

pub(crate) fn prepare_worker_schema_snapshot(
    target_worker_schema: u32,
) -> Result<Option<persistence::ProfileSnapshot>, String> {
    persistence::ensure_worker_schema_snapshot(
        &crate::shared::foundation::paths::tron_home(),
        target_worker_schema,
    )
}

pub(crate) fn list_profile_snapshots() -> Result<Vec<std::path::PathBuf>, String> {
    persistence::list_profile_snapshots(&crate::shared::foundation::paths::tron_home())
}

pub(crate) fn verify_profile_snapshot(
    path: &std::path::Path,
) -> Result<persistence::ProfileSnapshot, String> {
    persistence::verify_profile_snapshot(path)
}

pub(crate) fn restore_profile_snapshot(
    path: &std::path::Path,
) -> Result<std::path::PathBuf, String> {
    persistence::restore_profile_snapshot(path, &crate::shared::foundation::paths::tron_home())
}

pub(crate) use contract::{
    CONTEXT_SUMMARY_FUNCTION, CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES, SESSION_TITLE_FUNCTION,
    WORKER_RELEVANCE_FUNCTION, estimate_context_summary_tokens, validate_context_summary_narrative,
};

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
