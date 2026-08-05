//! Trusted-local persistent worker kernel.
//!
//! This domain is the executable self-extension path. A complete bundle is
//! staged, dependency-locked, smoke-tested, atomically versioned, and activated
//! by one `worker_upsert` call. Direct bundles also publish a typed model tool;
//! internal bundles retain their hooks, triggers, dispatches, client actions,
//! and authenticated generic invocation without entering the model surface.
//! Acquisition seals dependency checksums before hashing; bounded UTF-8 source
//! imports reject symlinks and special files. Filesystem bundles are canonical,
//! while SQLite owns rebuildable indexes and durable operational evidence.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `agent_delivery_effects` | Closed worker-declared Agent Delivery effect parsing and bounds |
//! | `artifacts` | Closed self-result artifact admission for native custody |
//! | `contract` | Function-owned model audiences plus request, response, and worker-bundle schemas |
//! | `dispatches` | Closed asynchronous worker-to-worker handoff parsing and limits |
//! | `handlers` | Model/client operation bindings |
//! | `host` | Bounded trusted-local filesystem, process, and network primitives |
//! | `notifications` | Narrow worker-to-client delivery validation and APNs transport |
//! | `persistence` | Canonical bundles, worker-owned state, verified profile/purge archives, index reconstruction, and durable operational ledgers |
//! | `process` | Bounded child-process I/O and isolated process-tree lifecycle shared by tools and runners |
//! | `retrieval` | Shared deterministic worker ranking and semantic-router recovery |
//! | `runtime` | Activation, runners, lifecycle, dispatch, dynamic tools, semantic engine hooks, and supervision |
//! | `surface` | Canonical fixed/dynamic model-tool selection and provider-neutral introspection evidence |
//! | `types` | Worker bundle and durable runtime DTOs |
//! | `wakeups` | Closed self-only durable wakeup parsing and bounds |
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
//! Every model-facing function definition owns its provider name, audience,
//! group, stable order, and closed top-level response contract; there is no
//! parallel primitive manifest. Function definitions carry one closed typed model-tool projection;
//! magic metadata keys cannot silently add tools, routing modes, or test-only
//! ranking inputs. Resolved provider entries are callable by construction;
//! availability is decided once during catalog projection rather than copied
//! into a second boolean. Every provider request records the exact catalog
//! revision, function revisions, selected and omitted worker versions, routing
//! mechanism, bounded ranking evidence, reasons, and surface hash.
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
//! The ordinary main-agent surface always includes the bounded coordination
//! primitives for discovery, invocation, authorized result reads,
//! invocation-scoped cancellation, durable waits, and Agent Delivery/mailbox
//! operations. Worker administration (`upsert`, inspection/list management,
//! lifecycle mutations, rollback, retirement, purge, global run audit, and
//! detach) remains specialist- or client-only. An agent worker receives only
//! its immutable `agentTools` allowlist and must declare `worker_invoke` plus a
//! positive child budget when its production role launches another worker.
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
//! Creation-time mailbox policy sees only bounded redacted previews and runs
//! asynchronously. Its selected IDs are validated against the candidate set
//! and claimed all-or-none. It cannot delay or wake the initial prompt;
//! subsequent mailbox consumption is explicit through list/claim tools.
//! Model-facing run and inbox reads are compact and bounded by default. An
//! explicit operator detail request expands at most twenty records and still
//! caps each retained input, output, or result, preventing durable history from
//! becoming an unbounded provider-context or transport payload.
//! Inbox Attention is derived rather than stored: only unresolved error and
//! setup-blocker evidence is active. Successful informational outcomes remain
//! immutable history even when they came from schedules, dispatches, or
//! background work. Detached top-level background results originating from an
//! ordinary agent session are delivered exactly once through the transactional
//! Agent Delivery outbox. Internal `engine_hook:*` invocations never enter that
//! generic result path: Continuity and relevance remain run-scoped, Session
//! Title applies directly, and mailbox curation uses its explicit claim path.
//! Foreground and nested results return to their caller unless an explicit
//! wait references them. Registering that wait supersedes an unprepared
//! default passive delivery, so one terminal result cannot produce both a
//! passive update and an automatic-resume wake. A
//! later successfully verified activation or rollback resolves
//! older errors for that worker, while a plain enable toggle is not recovery
//! evidence. Resolved errors remain immutable in run and delivery audit history
//! but are excluded from active Attention and future agent-context candidates.
//! Workers may declare the closed `notification_delivery` client-delivery
//! capability. Their successful top-level output is validated before commit,
//! and logical delivery intents are inserted in the same SQLite transaction as
//! terminal invocation evidence. Worker plus deduplication key is the logical
//! identity. Installations, per-installation targets, append-only APNs
//! attempts, synchronized read state, and idempotent fixed responses remain
//! engine-owned; provider acceptance is named `accepted_by_apns`, never
//! delivered. Missing readiness creates durable Attention without turning a
//! successfully accepted worker result into failure. Tokens and provider keys
//! never enter responses, logs, worker bundles, or purge exports.
//! Workers may separately declare the closed `artifact_delivery` capability.
//! An artifact can name only base64 bytes at an RFC 6901 pointer in its own
//! validated invocation result. Completion gives those bytes content-addressed
//! custody in `workers.sqlite` atomically with the canonical result and source
//! trace. Artifact metadata and bytes persist until an authenticated explicit
//! delete; workers cannot provide URLs, filesystem paths, client commands, or
//! draft mutations. Whole-worker-database pressure crosses into one
//! transition-aware Attention record; it never silently evicts user artifacts
//! or produces one error per retry.
//! Workers may declare the closed `agent_delivery` engine capability and a
//! bounded `agentDeliveries` result. Completion validates effects and commits
//! them beside terminal truth in `workers.sqlite`; import derives sender,
//! workspace, trace, root, depth, and authority rather than trusting worker
//! output. A rejected poison row remains durable evidence and never blocks
//! later rows.
//! The Engine Dashboard exposes active hook ownership. `continuity_context`,
//! `context_summary`, `mailbox_curation`, `session_organization`,
//! and `session_title` are production hooks. Worker selection is deterministic
//! kernel policy rather than a worker-owned semantic hook. Context
//! summary retains deterministic recovery because compaction is required for
//! the provider bound. Continuity and semantic relevance run asynchronously
//! and may affect only a later safe turn in their originating run. Session
//! naming deliberately has no generated fallback.
//! `continuity_context` is a minimal fixed projection seam for one production
//! Continuity Curator worker. The worker exclusively owns records, retention,
//! project/global scope, retrieval, ranking, correction, promotion, and
//! deletion. The provider runtime supplies only the bounded current request
//! and canonical working-directory identity. Publication proves that every
//! owner schema accepts the complete 12,000-character engine query boundary
//! before activation; the Continuity bundle's smoke and health checks exercise
//! that same executable boundary. The runtime then redacts credential-shaped
//! text and injects at most one bounded narrative. Provider context is
//! engine-owned and cannot be mutated safely from a worker process; that
//! custody is the reason for the seam. It cannot select records, inspect worker
//! state, choose retention, or manufacture fallback memory.
//! Worker calls have a sixty-second default policy ceiling, and an
//! immutable bundle may tighten the same generic invocation ceiling for every
//! runner kind. Optional policy timeout/failure is recorded outside the
//! provider critical path. Exact canonical relevance input may reuse the
//! ordinary durable invocation ledger within a thirty-second window; owner
//! version, hook identity, input bytes, and window all participate in the
//! idempotency key, so there is no second cache subsystem. Session-title,
//! compaction, continuity, and mailbox-curation hooks retain causal
//! idempotency. Successful hook results remain durable audit evidence;
//! malformed output and ordinary hook failures remain actionable.
//! The authenticated `engine::surface_snapshot` read returns the selected
//! surface revision/hash/counts, every published worker's projection status,
//! active engine-hook and native-client-action ownership, the complete
//! fixed-tool inventory, canonical engine worker summaries, and a compact
//! relationship graph derived from active immutable bundle declarations.
//! Architecture nodes include exposure, runner, hooks, triggers, client
//! boundaries, dispatch routes, exact `agentTools` dependencies, presentation
//! suite, version, health, and provenance. This is introspection only: it adds
//! no compiled hierarchy, routing policy, or second registry. Exact provider
//! contracts are not duplicated into the client response. It is not itself
//! model vocabulary and reports executable runtime facts rather than a
//! separately maintained description of the source tree.
//! Fixed inventory is always inspectable, while contract-declared latest-user
//! intent exposure may keep an actuator out of unrelated provider turns.
//! Worker-first operation is the engine architecture rather than an editable
//! mode or secondary lifecycle.
//! Explicit discovery and automatic projection share one deterministic local
//! scorer using exact field-weighted tokens and bounded adjacent phrases.
//! Conversation framing and substring collisions therefore cannot manufacture
//! relevance, and provider admission never depends on another worker run.
//! Mailbox curation and continuity hooks are user-session context only; this prevents cross-hook
//! recursion and keeps internal worker protocols isolated. Mutable
//! run/health evidence is a rebuildable engine-state overlay, not
//! function-contract text; successful work therefore cannot churn catalog
//! revisions. Fixed invocation and public/internal worker tools share one durable
//! interaction contract. Top-level agent runners begin in the background;
//! command and service versions use completed exact-version p95 evidence after
//! five samples. Unknown or predicted-fast work gets at most ten seconds in the
//! foreground, after which the same invocation is atomically detached rather
//! than cancelled or recreated. Nested worker calls remain synchronous because
//! their parent requires the typed result. Each nested worker call also owns a
//! durable parent/per-tool occurrence slot. A reconstructed agent attempt
//! starts those occurrences from zero, so changed provider call ids or
//! regenerated valid arguments observe the original completed/running child
//! instead of admitting duplicate specialist work. `worker_await` is bounded
//! by the same interaction budget, and `worker_detach` only changes
//! interaction ownership.
//! Exact terminal worker output is validated and owned once by the durable
//! invocation ledger. Every successful invocation has an integrity row in the
//! generic payload schema. Values at or below the shared 8 KiB boundary remain
//! inline in `worker_invocations`; larger values are SHA-256-addressed,
//! zstd-compressed blobs in `workers.sqlite`. Inbox, history, Session Context,
//! and run graphs carry compact `worker_result_reference` receipts rather than
//! copying the typed value. Exact hydration is limited to synchronous/nested
//! delivery, engine-hook application, explicit bounded result reads, recovery,
//! and purge export. `worker_result_read` returns only one bounded RFC 6901
//! path/page (at most 32 KiB and twenty items). Agent and worker callers require
//! the originating session or an explicit Agent Delivery grant; authenticated
//! paired clients and system recovery may inspect profile-local results. That
//! page is present in full for the immediately
//! following provider turn, then the agent context keeps only its reference
//! and pointer coordinates; a worker explicitly re-reads it if later reasoning
//! needs the bytes. References preserve worker version, output-schema
//! digest, content digest, size, and preview. Workers decide which paths or
//! references their typed orchestration needs; the kernel never interprets
//! source, claim, citation, or report fields. Generic payload previews prefer
//! conventional summary/answer text and otherwise describe only the JSON
//! shape; they never reintroduce an arbitrary serialized-body prefix. A
//! coordinator can therefore pass a causal result reference plus a
//! worker-schema-constrained list of RFC 6901 paths. The downstream worker
//! reads only those paths, verifies the returned reference identity, and keeps
//! all selection semantics in its immutable bundle.
//! The same immutable `presentation` envelope may declare a closed generic
//! native descriptor. Its bounded text, status, progress, table, list, HTTPS
//! link, artifact, confirmation, and same-worker action sections bind only to
//! RFC 6901 result paths read through `worker_result_read`. Fixed action inputs
//! pass the owning worker's complete input schema at bundle activation and use
//! ordinary invocation at runtime. HTML, JavaScript, custom client code,
//! arbitrary client commands, unsafe URL schemes, copied result bodies, and a
//! second presentation cache are not expressible.
//! Direct-worker session completions persist the originating provider-tool
//! association rather than another output body. That association is a
//! many-to-one durable relation: restart redelivery may regenerate a provider
//! tool-call id while the nested parent/per-tool slot correctly reuses the same
//! child invocation. Both the original and regenerated ids must therefore
//! resolve to that one canonical result without rewriting historical evidence.
//! An internal, non-model-visible projection resolves those associations within
//! the current session or causal trace: a trailing result at or below 8 KiB is integrity-verified and
//! hydrated for one accepted provider request, while large, background, and
//! historical results remain references. Provider admission, restart, token
//! estimation, and compaction all rebuild this projection from durable
//! evidence. A missing or corrupt fresh association fails before the provider
//! request and is reported as kernel storage failure rather than worker failure.
//! Schema v10 stages historical result ownership in restart-safe bounded
//! transactions while leaving schema-v9 rows readable, then atomically swaps
//! large outputs to internal envelopes, replaces successful inbox copies with
//! receipts, verifies every owner/hash/blob, and records the version. The
//! verified pre-migration profile snapshot remains the rollback boundary.
//! Schema v11 adds notification installations, logical deliveries, targets,
//! attempts, responses, and quiet-refresh state while preserving that same
//! snapshot and recovery discipline.
//! Schema v12 adds fixed asynchronous worker handoffs and split notification
//! source/producer ownership. Source completion, deduplicated handoff evidence,
//! and the immutable target invocation commit atomically. Children inherit
//! trace and origin session, increment causal depth, and identify their source
//! invocation as parent. A source route may retain fixed client-response
//! ownership without allowing worker output to choose its response destination.
//! Schema v13 adds one self-only delayed invocation to the same transactional
//! completion boundary. The worker owns the next useful time and typed input;
//! the kernel stores only `not_before`, the immutable source linkage, and
//! restart-safe queue custody. Claiming arms one synchronous drop finalizer;
//! terminal commit disarms it. Task abort, panic, or an unhandled error
//! therefore interrupts and requeues the attempt before its in-process owner
//! disappears. A separate scope guard releases the in-flight identity and
//! cancellation registration on the same paths. A bounded dispatcher
//! reconciler remains a defense for independently corrupted ownership rather
//! than the normal finalization path. Repeated orphan recovery is counted from
//! immutable interrupted-attempt evidence, so the third occurrence produces
//! one durable Attention item even when engine restarts separate the failures.
//! The fixed invocation envelope and each selected worker's nested input
//! schema are both transport admission boundaries. A nested schema or secret
//! violation is returned as an actionable invalid request before any durable
//! invocation exists; contract-loading and persistence failures remain
//! internal failures rather than being blamed on caller input.
//! Every newly activated direct bundle must declare a narrow
//! `toolInputSchema` for its model tool. Triggers, events, worker handoffs, and
//! authenticated generic invocation continue to use the complete
//! `inputSchema`; direct calls pass both boundaries before durable admission.
//! Internal occurrence, revision, mutation, and acknowledgement fields
//! therefore cannot silently become model ceremony. Canonical loading retains
//! the full-input fallback only for already-active migration bundles.
//! `modelExposure` is the closed ordinary-publication switch: `direct` is the
//! legacy default, while `internal` suppresses the worker from ordinary agent
//! discovery and provider surfaces. Internal versions retain one
//! system-visible function in the same catalog so an agent runner may name it
//! explicitly through `agentTools`; they do not gain a second registry or
//! invocation path. Hooks, triggers, client actions, worker dispatches, and
//! generic invocation continue to follow the same immutable version and
//! durable execution path.
//! This fixed seam is necessary because only the engine owns its callable
//! function catalog; a worker process cannot safely publish or remove its own
//! provider tool. The two-value contract carries no relevance or routing
//! policy, and the active immutable bundle remains its single owner.
//! Agent runners may additionally declare `agentTools`, an exact bounded list
//! of model-tool names for their child provider sessions. This fixed seam has
//! independent production callers in Engine Steward, Software Workspace,
//! Browser Operator, Mac Operator, Research Coordinator, General Delegate,
//! Worker Evaluator, and Worker Forge. A worker process cannot safely edit the
//! authenticated provider function catalog, so activation validates at most 32
//! unique 64-byte names against current fixed primitives, enabled direct or
//! internal worker functions, and the candidate's own declared tool. The immutable
//! bundle is the single owner; the allowlist crosses the existing causal
//! context and exact fixed/dynamic filtering occurs at the existing provider
//! boundary. Absence preserves the migration surface and an explicit empty
//! list exposes no tools. Restart reloads the same immutable bundle, missing
//! tools fail closed at projection, and neither the field nor the filter
//! carries relevance, workflow, retry, or other semantic policy.
//! Internal targets remain `FunctionVisibility::Internal`. The exact trusted
//! surface is resolved under the System actor, and execution uses that actor
//! only for the already-resolved target while retaining the originating worker
//! as causal ownership. Ordinary Agent and Worker actors still cannot discover
//! or invoke an internal function directly.
//! Verification evidence inside an immutable version is deterministic.
//! Activation time belongs to the append-only `worker_health` ledger, so
//! re-verifying byte-identical source reuses one content version while still
//! recording each successful activation and its recovery meaning.
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
//! Immutable bundles may choose generic `maxInvocationSeconds`,
//! `maxAgentTurns`, and `maxChildInvocations` ceilings. Invocation time applies
//! to every runner kind and can only tighten the global two-hour maximum. The
//! agent runtime can only tighten its global turn limit, while child admission
//! counts canonical parent links in the same SQLite transaction as insertion
//! so a concurrent tool batch cannot race beyond its parent's ceiling. Source,
//! claim, citation, model, and repair policy remain worker-owned.
//! Agent runners may select default `model` and provider-neutral
//! `reasoningLevel` values. A normal manual invocation may override either;
//! admission validates the exact model capability, records requested and
//! effective policy, and pins the effective pair across retries. Command and
//! service runners reject model overrides. Execution still uses the existing
//! authenticated model path and adds no secondary credential owner.
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
//! Successful one-shot title finalization prepares one closed internal dispatch
//! to the active `session_organization` worker and commits that child admission
//! in the same `workers.sqlite` transaction as the title worker's terminal
//! result. A failed transaction leaves the source invocation running for the
//! existing finalization/recovery path; organization work is never reduced to a
//! best-effort log after the canonical title compare-and-set. Organization
//! policy defaults and preferences stay in worker-owned state. The only
//! canonical mutation seam is a closed bounded batch with optional replacement
//! labels/group plus preserve/archive/restore. Omission preserves the canonical
//! field and explicit null clears only the group, allowing a simple direct
//! session-ID/outcome tool without destructive read-before-write ceremony.
//! Completion admits that exact intent atomically to `workers.sqlite`; the
//! existing dispatcher later applies it idempotently to canonical
//! `sessions.tags`/`ended_at`, with bounded infrastructure backoff and
//! stale-owner recovery. No per-turn polling, delete, arbitrary tag, or second
//! organization cache exists.
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
//! An agent-runner drop guard aborts its child on timeout, stop, disable, or
//! shutdown. Causal depth survives the child hop, and pre-admission event
//! subscription preserves even an immediate provider failure's terminal error.
//! The child prompt carries the immutable output schema verbatim and explains
//! that the kernel will validate it, so typed execution never asks a model to
//! satisfy a hidden contract.
//! Purge removes live worker state only after creating a verified recovery
//! archive, while retirement remains directly reversible from retained
//! versions.
//!
//! ## Test Ownership
//!
//! Unit tests live beside each concern; cross-domain replay,
//! provider-tool, transport, and client proofs live under `packages/agent/tests`.

use std::sync::Arc;

use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};

mod agent_delivery_effects;
mod artifacts;
mod contract;
mod dispatches;
mod handlers;
mod host;
mod notifications;
mod persistence;
mod process;
mod retrieval;
mod runtime;
mod session_organization;
mod surface;
#[cfg(test)]
mod tests;
mod types;
mod wakeups;

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
    CONTEXT_SUMMARY_FUNCTION, CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES, CONTINUITY_CONTEXT_FUNCTION,
    SESSION_TITLE_FUNCTION, WORKER_RESULT_PROJECTION_FUNCTION, estimate_context_summary_tokens,
    validate_context_summary_narrative,
};

pub(crate) use notifications::apns::validate_private_key as validate_apns_private_key;
pub(crate) use runtime::WorkerRuntime;
#[cfg(test)]
pub(crate) use surface::{AvailableWorkerToolSnapshot, SurfaceToolSnapshot};
pub(crate) use surface::{
    EngineSurfaceSnapshot, ResolvedToolSurface, promote_worker_for_session, resolve_tool_surface,
};

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
    let functions = handlers::bind_functions(
        contract::function_definitions()?,
        handlers::Deps {
            runtime: Arc::clone(&runtime),
        },
    )?;
    let (engine_functions, functions): (Vec<_>, Vec<_>) = functions
        .into_iter()
        .partition(|registration| registration.definition.id.namespace() == "engine");
    Ok(Registration {
        functions,
        engine_functions,
        runtime,
    })
}
