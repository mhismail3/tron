//! Domain-owned primitive engine surface.
//!
//! Each declared child module is part of the retained bare loop: startup and
//! system metadata, provider/auth/settings setup, session/message/log truth,
//! model providers, blobs, catalog-discovery evidence, approval/freshness
//! evidence, memory contract custody, durable media/voice-note resource
//! custody, durable import/session-resource graph lineage records, durable
//! content-free repository tree snapshot records, durable import preview
//! records, durable program execution metadata records, durable prompt artifact
//! metadata records, durable system update diagnostic metadata records,
//! inspect-only module manifest registry records, durable non-interactive jobs,
//! read-only Git/worktree observation,
//! goal/question lifecycle records, direct web source fetch provenance, inert
//! external tool-source proposal provenance, inert subagent task lifecycle
//! records, inert procedural state provenance records, and the single model-facing
//! `capability::execute` primitive, plus the narrow iOS workspace-browser
//! filesystem domain. Product/tool domains are otherwise intentionally not
//! declared on this branch.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `capability` | Single model-facing `execute` primitive |
//! | `approval` | Approval request/decision evidence and reusable freshness checks |
//! | `catalog_discovery` | Native catalog search, inspect, and conformance evidence |
//! | `device` | Server-owned device registration and redacted APNs token custody |
//! | `memory` | Memory contract resources, prompt traces, and migration envelopes |
//! | `media` | Durable media/voice-note resources with blob refs and redacted projections |
//! | `import_history` | Durable import/session-resource graph lineage records |
//! | `repository_tree` | Durable content-free repository tree snapshot records |
//! | `import_preview` | Durable content-free import preview records |
//! | `program_execution` | Durable content-free program execution metadata records |
//! | `prompt_artifacts` | Durable explicit prompt artifact metadata records |
//! | `update_diagnostics` | Durable system update diagnostics metadata records |
//! | `module_registry` | Inspect-only module identity/declaration manifest registry |
//! | `jobs` | Durable non-interactive local process jobs and lifecycle resources |
//! | `git` | Read-only repository/worktree status and bounded diff evidence |
//! | `goals` | Goal and user-question lifecycle records |
//! | `web` | Direct web fetch source provenance resources |
//! | `tool_sources` | Inert external tool-source proposal and preflight evidence |
//! | `subagents` | Inert subagent task lifecycle evidence |
//! | `procedural` | Inert skill/rule/hook/procedure provenance inspection evidence |
//! | `scheduler` | Durable schedules, missed-run policy, cancellation, and run records |
//! | `notifications` | Durable notification inbox, read state, badges, and delivery evidence |
//! | `registration` | Startup registration plus shared domain contract/binding helpers |
//! | `filesystem` | Human-facing workspace picker: home, directory list, folder creation |
//! | domain modules | Retained loop infrastructure for agent, auth, blob, logs, message, model, session, settings, system, transcription, and worker lifecycle |
//!
//! Each retained domain `contract.rs` is the local source of truth for that
//! worker's function ids, schemas, idempotency, leases, compensation, stream
//! topics, and operation keys. Each domain `deps.rs` narrows setup context into
//! the service handles that worker actually needs. `handlers.rs` is a
//! declarative operation-key binding table backed by the shared method-agnostic
//! `bindings` helper, so completeness failures happen during worker
//! construction instead of as late runtime branches.
//!
//! ## Entry Points
//!
//! The intended execution flow is:
//! `/engine frame -> EngineTransportRequest -> EngineTriggerRuntime -> domain
//! worker -> contract operation key -> handlers.rs -> domain owner -> narrow
//! deps/service -> engine ledger/streams/queues/grants/leases`.
//!
//! Startup enters the domain tree through
//! `transport::runtime::setup::register_server_domains_for_context`. That
//! facade delegates to the crate-private registration owner, which is the only
//! non-test code allowed to wire concrete domain worker modules. Individual
//! domains expose their public behavior through `contract.rs` definitions and
//! handler tables, not through transport-specific functions.
//!
//! ## Invariants
//!
//! Domain methods here are canonical operation keys only. Public client
//! protocols translate into the transport-neutral engine envelope before
//! reaching these handlers.
//!
//! Product/tool domains retired by the primitive teardown must remain absent
//! from this module tree and startup registration unless a restoration slice
//! reintroduces the behavior as a narrow worker-owned contract. The filesystem
//! domain is restored only for the iOS workspace selector and must not regain
//! agent read/write/search/diff/apply-patch tools in Phase 1. The
//! transcription domain is restored only as local speech-to-text for composer
//! input; saved voice-note/media custody lives in the media domain as blob refs
//! and bounded metadata, without native capture UI or server transcription
//! model changes. Import/history restoration is resource-backed generic graph
//! lineage only; raw repository trees, import payloads, and native session tree
//! UI remain absent until a later slice proves generic rendering is
//! insufficient. Repository tree restoration is content-free snapshot metadata
//! only: it stores repository/root refs, tree object refs, bounded relative path
//! metadata, counts, and evidence refs without raw file contents, blob bytes,
//! absolute paths, repository visualization, or git mutation workflows. Import
//! preview restoration is content-free ref and metadata custody only: it links
//! import-history and repository-tree refs with bounded normalized relative path
//! metadata and preview fingerprints without raw import payloads, file contents,
//! repository contents, import execution, visualization, or git mutation.
//! Program execution restoration is content-free metadata custody only: it
//! stores runtime/language ids, I/O refs or fingerprints, resource-limit policy,
//! trace/replay refs, and lifecycle evidence without raw code, command strings,
//! raw stdin/stdout/stderr, subprocesses, runtime installs, file writes, network
//! behavior, result merge, or native UI. Update
//! Prompt artifact restoration is metadata-only explicit artifact custody: it
//! stores artifact kinds, bounded titles/summaries/previews, content refs or
//! fingerprints, retention state, trace/replay refs, and lifecycle evidence
//! without raw prompt bodies, automatic prompt-history capture, provider-visible
//! raw prompt payloads, prompt injection, learned behavior, context inclusion,
//! native snippet/template UI, or settings/profile migration. Update
//! diagnostics restoration is metadata-only signed-release and provenance
//! custody: it does not perform live update checks, execute
//! installers, restart processes, register packages/catalog entries, expose
//! production endpoints, or add native update panels. The worker lifecycle
//! domain is the post-baseline package/launch substrate for
//! self-updating workers; it is not a restored product tool domain. The git
//! domain is restored only for read-only status/diff evidence; source-control
//! mutations remain absent. The procedural domain is resource-backed custody
//! and inspection evidence only; activation, trigger firing, prompt injection,
//! learned behavior, and autonomous execution remain absent. Device and
//! notification domains are server-owned foundations only: raw APNs tokens are
//! not provider-visible, live APNs transport and native iOS inbox affordances
//! remain absent, and the old notification product surface is not restored.
//! Module registry restoration is inspect-only source-backed manifest custody:
//! it stores first-party `module_manifest` resources and provider-safe
//! list/inspect projections without module install, activation, execution,
//! dependency resolution, network behavior, public `/engine` expansion, or
//! native marketplace panels. New domain behavior must add a contract, deps
//! narrowing, handler binding, tests, and README/domain-doc updates together.
//!
//! ## Test Ownership
//!
//! Domain-local tests live next to the domain service, provider, or store they
//! exercise. Shared registration/binding behavior belongs under
//! `domains/registration`; end-to-end transport/domain routing belongs in
//! integration/static tests rather than a broad domain root test.

pub mod agent;
pub mod approval;
pub mod auth;
pub mod blob;
pub mod capability;
pub mod catalog_discovery;
pub mod device;
pub mod filesystem;
pub mod git;
pub mod goals;
pub mod import_history;
pub mod import_preview;
pub mod jobs;
pub mod logs;
pub mod media;
pub mod memory;
pub mod message;
pub mod model;
pub mod module_registry;
pub mod notifications;
pub mod procedural;
pub mod program_execution;
pub mod prompt_artifacts;
pub mod registration;
pub mod repository_tree;
pub mod scheduler;
/// Session domain: lifecycle, reads, reconstruction, and context artifact services.
pub mod session;
pub mod settings;
pub mod subagents;
pub mod system;
pub mod tool_sources;
pub mod transcription;
pub mod update_diagnostics;
pub mod web;
pub mod worker_lifecycle;
