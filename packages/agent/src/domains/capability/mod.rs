//! Primitive execute domain worker.
//!
//! This module owns the only model-facing tool on the primitive branch:
//! `capability::execute`. Concrete host actions happen through direct primitive
//! operations after the trusted agent runtime derives a least-privilege child
//! grant for the current call. `replay_manifest` is the read-only evidence
//! operation: it returns the current session replay manifest without creating a
//! trace record. Catalog-discovery operations are inspect-only additions to the
//! same primitive: search/inspect read current metadata, while conformance
//! writes only durable catalog-discovery report evidence.
//! Git branch-start is intentionally a git-domain operation under this
//! primitive: it creates one local branch and moves symbolic `HEAD`, but it does
//! not expose arbitrary checkout or branch-management targets.
//! Memory audit operations are also inspect-only additions: they expose
//! resource-backed memory status/list/inspect facts without retaining or
//! injecting private memory body content.
//! Media operations are resource-backed metadata operations: they create,
//! list, inspect, and archive `media_artifact` records that point at blob refs
//! while rejecting raw media bytes and keeping provider projections redacted.
//! Import-history operations are resource-backed lineage operations: they
//! record, list, and inspect bounded `import_history_record` graph metadata
//! without storing raw import payloads, repository trees, or native UI state.
//! Repository-tree operations are resource-backed metadata operations: they
//! snapshot, list, and inspect content-free `repository_tree_snapshot` records
//! with bounded relative path metadata, refs, and counts, without raw file
//! contents, blob bytes, absolute paths, visualization, or git mutation.
//! Import-preview operations are resource-backed metadata operations: they
//! record, list, and inspect content-free `import_preview` records linking
//! import-history and repository-tree refs with bounded path metadata and
//! fingerprints, without raw import payloads, file contents, import execution,
//! visualization, or git mutation.
//! Program-execution operations are resource-backed metadata operations: they
//! record, list, and inspect content-free `program_execution_record` records
//! with runtime/language identifiers, resource-limit policy, I/O-envelope refs,
//! fingerprints, and lifecycle evidence, without storing code or I/O bytes and
//! without launching runtimes, subprocesses, package managers, or networks.
//! Prompt-artifact operations are resource-backed metadata operations: they
//! record, list, and inspect explicit `prompt_artifact` records with bounded
//! title/summary/preview fields and content refs/fingerprints only, without raw
//! prompt body storage, automatic capture, prompt injection, learned behavior,
//! provider-visible raw prompt payloads, or native snippet/template UI.
//! Update-diagnostics operations are resource-backed metadata operations: they
//! record, list, and inspect bounded `update_diagnostic_record` signed-release
//! and provenance facts without live update checks, package bytes, install or
//! restart execution, package/catalog registration, or deploy automation.
//! Module-manifest operations are read-only resource-backed operations: they
//! list and inspect provider-safe `module_manifest` projections without module
//! install, activation, execution, dependency resolution, network behavior, or
//! raw manifest exposure.
//! Module-authoring operations are inert resource-backed operations: they
//! record, list, and inspect bounded `module_proposal` metadata and refs
//! without module workspace directories, install, activation, execution,
//! dependency restoration, network behavior, repo-managed skills, raw prompt
//! bodies, or raw proposal bodies; their trace records use a redacted
//! request/authority projection before module-authoring validation runs.
//! Module-validation operations are inert resource-backed operations: they
//! record, list, and inspect bounded `module_validation_report` evidence with
//! module/proposal refs, parity checks, docs/tests evidence, command/result
//! refs, failure evidence, trace/replay refs, lifecycle, and no-install/no-
//! execution proof without running commands or module code, storing raw logs,
//! commands, env values, code, or file contents, touching repo-managed skills,
//! resolving dependencies, accessing networks, installing, or activating.
//! Module-install operations are metadata-only review-gate operations: they
//! record, list, and inspect `module_install_request` and
//! `module_install_decision` resources linked to passed validation reports,
//! approval freshness evidence, dependency policy refs, and rollback proof
//! refs without installing, enabling, executing, restoring dependencies,
//! running package managers, touching repo-managed skills, or accessing
//! networks.
//! Module-dependency operations are metadata-only policy operations: they
//! record, list, inspect, and activate `module_dependency_*` resources with
//! owner rationale, review decisions, Cargo parity evidence, and no dependency
//! restoration, package-manager use, manifest/lockfile mutation, or network
//! access.
//! Capability-binding operations are metadata-only governance operations: they
//! record, list, inspect, decide, and activate `capability_binding_*` resources
//! for future shadow/extend/replace proposals after deriving target operation
//! ownership metadata from the execute registry, with contract/evidence
//! requirements, authority/network constraints, stale-version guards,
//! rollback/disable refs, and audit refs, while proving no `capability::execute`
//! dispatch, runtime routing, hot-swap, module activation, package-manager,
//! dependency, or network behavior occurs.
//! `capability_binding_cockpit_overview` exposes the same read-only Engine
//! Cockpit projection used by native clients so the agent can inspect operation
//! ownership, replacement class, route state, and exact preflight guidance. An
//! exact `targetOperation` filter returns one operation row and a matching
//! targeted content summary with the safe read-only path and unavailable-surface
//! guidance, while the full projection remains durable UI/audit data. The turn
//! runner appends a bounded
//! provider-visible digest with coverage counts, family summaries, and
//! representative operation samples so the agent can verify the pool without
//! guessing or calling internal catalog functions directly.
//! `catalog_search` is the agent-native entry point for operation discovery:
//! exact and prefix operation queries return direct `capability::execute`
//! arguments plus a preferred `catalog_inspect` step for the `execute::<operation>`
//! schema before backing catalog-function diagnostics, unsupported
//! operation-like names return explicit recovery guidance instead of fuzzy near
//! matches, read-only searches include one merged `allDiscoveredInspectTargets`
//! list for both immediately callable read-only matches and supported
//! effect-excluded operations that should be inspected but not invoked, and
//! readiness searches that name one runtime-routable target operation return a deterministic read-only
//! `agentSearchPlan` limited to the exact inspect/list sequence before the
//! model needs to inspect cockpit details. Trace/evidence searches that name one
//! target operation return a separate read-only plan: inspect the
//! `execute::<operation>` schema, invoke the target once, then inspect
//! provider-safe trace evidence with `trace_list` instead of routing the agent
//! through replacement-readiness surfaces; `trace_get` is reserved for focused
//! per-record detail after `trace_list` returns an exact record id. Trace
//! projections name visible trace/invocation fields as safe engine refs, not raw
//! provider invocation ids, label the current `trace_list` invocation as pending
//! at projection time until completion is recorded, and separate
//! provider-visible capability safety from internal replay/policy bookkeeping.
//! Broad module-governance readiness searches return a deterministic read-only
//! plan over module registry/lifecycle/runtime/dependency, binding, candidate,
//! route, and route-event list surfaces. That plan marks default list payloads
//! as complete, discourages schema fan-out across every sibling operation,
//! treats empty lists as valid current-scope evidence, and keeps activation,
//! rollback, and write surfaces out of read-only checks.
//! `catalog_search`
//! accepts the safe read-only `effectClass` aliases `read`, `read_only`, and
//! `inspect` as `pure_read` so natural discovery filters do not become invalid
//! calls; read-only searches must return only operations whose agent-usage
//! metadata proves they are inspection-safe and non-mutating in both immediate
//! matches and generic supported-operation fallback guidance, so broad resource
//! discovery queries cannot steer the model into write or record operations.
//! Supported operations excluded by the requested read-only effect class are
//! reported separately with bounded operation metadata and an explicit
//! "do not invoke during pure-read discovery" reason, so the model can
//! distinguish an unsafe supported operation from a nonexistent one.
//! The result summary also states whether the execute-operation search was
//! complete or truncated and how many supported operations were effect-excluded,
//! keeping those facts in the model's primary answer surface.
//! Preferred next-step guidance may include an immediate `thenInvoke` only for
//! read-only, non-mutating operations; write-like operations get schema
//! inspection plus an explicit blocked-invoke reason instead.
//! `namespacePrefix` also matches capability-pool family/owner metadata, not
//! just literal operation-name prefixes, so family searches surface sibling
//! operations such as context policy lists even when names differ.
//! `catalog_inspect` accepts
//! `execute::<supported_operation>` and supported-operation ids directly; those
//! aliases return operation-specific call contracts, preflight guidance, and
//! required top-level payload fields in both normalized `inputSchema` /
//! `outputSchema` slots and the operation-specific schema block instead of the
//! generic `capability::execute` wrapper. Inspect operations must expose their
//! exact resource-id field names; placeholder fields are rejected because they
//! force the model to infer hidden request syntax. Runtime-routable operations
//! keep their capability-pool classification, but operation inspection also includes a
//! `currentInvocation` boundary so normal read-only/session calls are not
//! confused with explicit replacement, shadow, route, disable, or rollback
//! workflows.
//! Capability-shadow-trial operations are an even narrower metadata-only path:
//! they record request/decision/run/evidence resources for the selected
//! read-only `git_status` target, compare bounded built-in and deterministic
//! candidate projections, require exact selectors plus rollback/disable/abort
//! refs, and never execute candidate modules or change live dispatch.
//! Module-lifecycle operations are metadata-only state operations: they
//! request/decide/list/inspect enable, disable, quarantine, and rollback
//! lifecycle records for install-candidate modules without installing,
//! activating, executing, restoring dependencies, running package managers,
//! touching repo-managed skills, or accessing networks.
//! Module-runtime operations request/list/inspect/cancel enabled-lifecycle-
//! guarded supervisor envelopes with bounded refs, sandbox/network/secrets
//! labels, timeout/cancel/shutdown metadata, and provider-safe output refs only,
//! without raw commands/logs/output, PTYs, browser automation, dependency
//! restoration, package-manager use, network access, or physical install.
//! Module program-execution operations activate the jobs/program execution pack
//! through `module_program_execution_start/status/cancel/cleanup`: they require
//! exact module runtime, module lifecycle, program execution, job process,
//! execution output, and resource selectors, delegate real process work to the
//! jobs domain, link content-free program execution metadata, update module
//! runtime supervision state, and trace-redact requests/results so provider
//! output remains bounded refs/fingerprints/truncation/duration/exit/timeout/
//! cancellation/cleanup metadata rather than raw command, code, stdio, logs,
//! paths, env, pids, grant ids, or raw job/output payloads.
//! File/Git module-pack activation is metadata and authority only: the existing
//! `filesystem_*` and selected `git_*` operation values remain inside this
//! primitive, but derived grants use exact filesystem/Git/resource scopes,
//! trusted working-directory roots, and existing evidence resource kinds
//! instead of implicit `agent_state` authority or new provider-visible tools.
//! Web network operations follow the same no-inheritance rule: `web_fetch` and
//! `web_robots_check` run only with explicit web/resource grants and must not
//! inherit `state.*` or `agent_state` authority from the parent turn.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Single `capability::execute` contract and provider schema |
//! | `capability_binding_contract` | Capability-binding and shadow-trial schema fields |
//! | `context_control_contract` | Context-control snapshot/action/epoch schema fields |
//! | `module_dependencies_contract` | Module-dependency request/decision/policy schema fields |
//! | `web_research_contract` | Web research request/review/source schema fields |
//! | `module_install_contract` | Module-install review request schema fields |
//! | `module_lifecycle_contract` | Module-lifecycle request schema fields |
//! | `module_runtime_contract` | Module-runtime supervisor schema fields |
//! | `module_validation_contract` | Module-validation request schema fields |
//! | `operations` | Direct primitive operation implementations |
//! | `pool` | Operation/catalog-function classification for agent-facing discovery |
//! | `scheduler_contract` | Schedule-specific request schema fields |
//!
//! # INVARIANT: the model-facing surface is tiny
//!
//! Provider integrations must expose exactly this one tool. Additional behavior
//! can only appear later as agent-owned state or generated helper substrate, not
//! as checked-in target functions.
//! Supported `execute` operation spellings live in the operations registry and
//! are reused by provider schema descriptions, provider guidance, catalog
//! discovery, unsupported-operation diagnostics, and stream/UI operation
//! identity. Do not duplicate freehand operation lists elsewhere.
//! File access through this tool must use the hardened `filesystem_*` operation
//! package registered in the operations registry.
//! Agent-launched executions persist trace provider ownership and canonical
//! working directory from trusted `CausalContext` runtime metadata, not from
//! model-id string parsing, shell aliases, caller-supplied public context, or
//! process-cwd inference. `capability::execute` rejects bootstrap/root grants and
//! runs only with derived scoped grants whose file roots, state authority, and
//! network policy match the requested primitive operation. Working-directory
//! metadata is required only for file/process operations; catalog discovery must
//! remain pure metadata inspection or resource-backed report creation. Replay
//! manifest reads deliberately bypass trace insertion so the exported manifest
//! is not changed by the read. Module-manifest reads deliberately stay inside
//! `capability::execute`; module-authoring proposal records and
//! module-validation reports deliberately stay inert, resource-backed, and
//! trace-safe before unsafe payload rejection. None expands the public
//! `/engine` protocol.

mod capability_binding_contract;
mod context_control_contract;
pub(crate) mod contract;
mod import_history_contract;
mod import_preview_contract;
mod media_contract;
mod module_dependencies_contract;
mod module_install_contract;
mod module_lifecycle_contract;
mod module_runtime_contract;
mod module_validation_contract;
mod operations;
pub(crate) mod pool;
mod program_execution_contract;
mod prompt_artifacts_contract;
mod repository_tree_contract;
mod scheduler_contract;

pub(crate) use operations::supported_operation_names;
pub(crate) use operations::{
    OperationBindingMetadata, is_supported_operation, operation_binding_metadata,
    operation_list_text,
};
mod update_diagnostics_contract;
mod web_research_contract;
pub(crate) use operations::execute_value;

use std::sync::Arc;

use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::jobs;
use crate::domains::registration::catalog::{CapabilitySpec, function_definition_for_capability};
use crate::domains::registration::worker::{
    DomainFunctionRegistration, DomainRegistrationContext, DomainWorkerModule,
};
use crate::domains::session::event_store::EventStore;
use crate::engine::{EngineError, InProcessFunctionHandler, Invocation};
use crate::shared::server::error_mapping::capability_error_to_engine;
use chrono::Utc;
use serde_json::Value;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) event_store: Arc<EventStore>,
    pub(crate) session_manager: Arc<SessionManager>,
    pub(crate) shutdown_coordinator:
        Option<Arc<crate::app::lifecycle::shutdown::ShutdownCoordinator>>,
    pub(crate) jobs_reconcile: jobs::service::ReconcileContext,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            event_store: Arc::clone(&deps.event_store),
            session_manager: Arc::clone(&deps.session_manager),
            shutdown_coordinator: deps.shutdown_coordinator.clone(),
            jobs_reconcile: jobs::service::ReconcileContext {
                startup_cutoff: Utc::now(),
            },
        }
    }
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    let mut registrations = function_registrations(contract::capabilities()?, domain_deps)?;
    for registration in &mut registrations {
        merge_metadata(
            &mut registration.definition.metadata,
            contract::model_metadata(registration.definition.id.as_str()),
        );
    }
    crate::domains::registration::worker::domain_worker_module(
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

fn function_registrations(
    specs: Vec<CapabilitySpec>,
    deps: Deps,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    let mut registrations = Vec::with_capacity(specs.len());
    for spec in specs {
        if spec.operation_key != "execute" {
            return Err(EngineError::PolicyViolation(format!(
                "unexpected capability operation '{}'",
                spec.operation_key
            )));
        }
        registrations.push(DomainFunctionRegistration {
            definition: function_definition_for_capability(&spec),
            handler: Arc::new(ExecuteHandler { deps: deps.clone() }),
        });
    }
    Ok(registrations)
}

struct ExecuteHandler {
    deps: Deps,
}

#[async_trait::async_trait]
impl InProcessFunctionHandler for ExecuteHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value, EngineError> {
        execute_value(&invocation, &self.deps)
            .await
            .map_err(capability_error_to_engine)
    }
}
