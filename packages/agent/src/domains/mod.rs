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
//! inspect-only module manifest registry records, inert module proposal
//! authoring records, inert module validation report records, metadata-only
//! module install review-gate records, metadata-only module dependency request
//! and policy records, metadata-only capability binding policy records,
//! inspect-only generic module activity cockpit projection, metadata-only web
//! research request/review/source custody,
//! durable non-interactive jobs, read-only Git/worktree observation,
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
//! | `context_control` | Context snapshots, compact/clear action records, and epochs |
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
//! | `module_authoring` | Inert bounded module proposal authoring records |
//! | `module_validation` | Inert bounded module contract validation reports |
//! | `module_install` | Metadata-only module review approval and install-candidate gate |
//! | `module_dependencies` | Metadata-only module dependency request, decision, and policy activation records |
//! | `capability_binding` | Metadata-only capability binding request, decision, and policy records |
//! | `module_lifecycle` | Metadata-only module enable/disable/quarantine/rollback state |
//! | `module_runtime` | Supervised module runtime envelope records for enabled modules |
//! | `module_activity` | Read-only generic module activity cockpit projection |
//! | `web_research` | Metadata-only web research request, review, and source artifact custody |
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
//! `transport::runtime::setup::register_server_domains_for_runtime_context`.
//! That facade delegates to the crate-private registration owner, which is the
//! only non-test code allowed to wire concrete domain worker modules. The
//! registration owner validates the full composition before catalog mutation
//! and returns a one-shot lifecycle token; transport setup activates it only
//! after transport triggers also register successfully.
//! Single-threaded test fixtures use the paired setup-only facade. Individual
//! domains expose their public behavior through `contract.rs` definitions and
//! handler tables, not through transport-specific functions.
//!
//! ## Invariants
//!
//! Domain methods here are canonical operation keys only. Public client
//! protocols translate into the transport-neutral engine envelope before
//! reaching these handlers.
//!
//! Every retained domain owns a narrow contract and registers only canonical
//! operation keys. Metadata-custody domains store bounded metadata and durable
//! refs; they cannot acquire execution, network, package-manager, or raw-content
//! behavior implicitly. Executing domains run only through engine authority,
//! exact selectors, lifecycle gates, and traceable results. Provider-facing
//! projections remain bounded and omit raw prompts, content, paths, commands,
//! logs, credentials, grant ids, authority ids, and hidden reasoning.
//!
//! Module governance owns proposal, validation, dependency, install, lifecycle,
//! runtime, binding, shadow, route, and rollback records. Module implementations
//! can extend or replace eligible operations only through that pipeline; they
//! cannot replace the authority, resource-custody, event, trace, redaction, or
//! governance substrate at runtime. New behavior must ship its contract,
//! narrowed dependencies, handler binding, tests, and current README/domain
//! documentation together.
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
pub mod capability_binding;
pub mod catalog_discovery;
pub mod context_control;
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
pub mod module_activity;
pub mod module_authoring;
pub mod module_dependencies;
pub mod module_install;
pub mod module_lifecycle;
pub mod module_registry;
pub mod module_runtime;
pub mod module_validation;
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
pub mod web_research;
pub mod worker_lifecycle;
