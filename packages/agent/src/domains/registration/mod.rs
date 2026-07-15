//! Domain worker registration.
//!
//! This module registers the in-process workers for the primitive engine.
//! Product surfaces enter startup through source-backed domain contracts and
//! inventory lineage.
//!
//! `capability` owns the only model-facing tool, `capability::execute`, and
//! that tool performs direct primitive operations rather than catalog routing.
//! The registration entrypoint is crate-private: transport setup is the
//! server-facing facade, while this module owns the concrete domain-worker
//! wiring, including the single jobs runtime state shared by the jobs worker
//! and capability adapters. `catalog` owns shared capability contract types
//! and stable registration identities without maintaining a second domain
//! enumeration.
//! `module_registry` owns the manifest resource contract, while
//! `module_manifests` owns the ordered first-party payload composition.
//! Registration installs both before any domain worker or function; the engine
//! owns only generic type registration and version-preserving reconciliation.
//! The complete production composition validates function ownership,
//! canonical identity uniqueness, and stream-topic boundaries before either
//! registration path mutates the engine catalog. Jobs and worker-lifecycle
//! activation is returned as a one-shot token so transport setup starts those
//! lifecycles only after domain and trigger registration both succeed.
//!
//! # INVARIANT: canonical capabilities are the executable surface
//!
//! Domain method names are internal operation keys for service routing only.
//! Only canonical function ids are registered.

pub(crate) mod bindings;
pub(crate) mod catalog;
pub(crate) mod contract;
mod module_manifests;
pub(crate) mod worker;

use std::collections::BTreeSet;

use crate::engine::{EngineError, EngineHostHandle, Result as EngineResult};
use crate::shared::server::context::ServerRuntimeContext;

use crate::domains::registration::worker::{
    DomainFunctionRegistration, DomainRegistrationContext, DomainWorkerModule,
};
use crate::domains::{
    agent, approval, auth, blob, capability, capability_binding, catalog_discovery,
    context_control, device, filesystem, git, import_history, import_preview, jobs, logs, media,
    memory, message, model, module_activity, module_authoring, module_dependencies, module_install,
    module_lifecycle, module_registry, module_runtime, module_validation, notifications,
    program_execution, prompt_artifacts, repository_tree, scheduler, session, settings, subagents,
    system, tool_sources, transcription, update_diagnostics, web, web_research, worker_lifecycle,
};

#[must_use = "activate after transport-trigger registration"]
pub(crate) struct DomainLifecycleActivation {
    jobs: jobs::Deps,
    worker_lifecycle: worker_lifecycle::Deps,
}

impl DomainLifecycleActivation {
    pub(crate) fn activate(self) {
        self.jobs.activate_after_registration();
        self.worker_lifecycle.activate_after_registration();
    }
}

struct DomainComposition {
    modules: Vec<DomainWorkerModule>,
    activation: DomainLifecycleActivation,
}

/// Register server-owned domain workers, canonical functions, and manifest records.
pub(crate) fn register_domain_workers_for_context(
    ctx: &ServerRuntimeContext,
) -> EngineResult<DomainLifecycleActivation> {
    let DomainComposition {
        modules,
        activation,
    } = domain_worker_modules(ctx)?;
    let handle = &ctx.engine_host;
    install_module_manifest_resources_for_setup(handle)?;
    for module in modules {
        handle.register_worker_for_setup(module.worker, false)?;
        for function in module.functions {
            handle.register_function_for_setup(
                function.definition,
                Some(function.handler),
                false,
            )?;
        }
    }
    Ok(activation)
}

/// Register server-owned domain workers, canonical functions, and manifest
/// records from async server startup.
pub(crate) async fn register_domain_workers_for_runtime_context(
    ctx: &ServerRuntimeContext,
) -> EngineResult<DomainLifecycleActivation> {
    let DomainComposition {
        modules,
        activation,
    } = domain_worker_modules(ctx)?;
    let handle = &ctx.engine_host;
    install_module_manifest_resources(handle).await?;
    for module in modules {
        handle.register_worker(module.worker, false).await?;
        for function in module.functions {
            handle
                .register_function(function.definition, Some(function.handler), false)
                .await?;
        }
    }
    Ok(activation)
}

#[cfg(test)]
pub(in crate::domains) fn install_module_manifests_for_test(
    handle: &EngineHostHandle,
) -> EngineResult<()> {
    install_module_manifest_resources_for_setup(handle)
}

fn install_module_manifest_resources_for_setup(handle: &EngineHostHandle) -> EngineResult<()> {
    handle.register_resource_type_for_setup(module_registry::resource_type_definition())?;
    handle
        .reconcile_source_resources_for_setup(module_manifests::builtin_module_manifest_resources())
}

async fn install_module_manifest_resources(handle: &EngineHostHandle) -> EngineResult<()> {
    handle
        .register_resource_type(module_registry::resource_type_definition())
        .await?;
    handle
        .reconcile_source_resources(module_manifests::builtin_module_manifest_resources())
        .await
}

fn domain_worker_modules(ctx: &ServerRuntimeContext) -> EngineResult<DomainComposition> {
    let deps = DomainRegistrationContext::from_context(ctx);
    let jobs_runtime = jobs::RuntimeState::new();
    let jobs_deps = jobs::Deps::from_engine(&deps, jobs_runtime.clone());
    let worker_lifecycle_deps = worker_lifecycle::Deps::from_engine(&deps);
    let mut modules = vec![
        system::worker_module(&deps)?,
        capability::worker_module(&deps, jobs_runtime)?,
        catalog_discovery::worker_module(&deps)?,
        approval::worker_module(&deps)?,
        device::worker_module(&deps)?,
        notifications::worker_module(&deps)?,
        context_control::worker_module(&deps)?,
        media::worker_module(&deps)?,
        import_history::worker_module(&deps)?,
        repository_tree::worker_module(&deps)?,
        import_preview::worker_module(&deps)?,
        program_execution::worker_module(&deps)?,
        prompt_artifacts::worker_module(&deps)?,
        update_diagnostics::worker_module(&deps)?,
        module_registry::worker_module(&deps)?,
        module_authoring::worker_module(&deps)?,
        module_validation::worker_module(&deps)?,
        module_install::worker_module(&deps)?,
        module_dependencies::worker_module(&deps)?,
        capability_binding::worker_module(&deps)?,
        module_lifecycle::worker_module(&deps)?,
        module_runtime::worker_module(&deps)?,
        module_activity::worker_module(&deps)?,
        web_research::worker_module(&deps)?,
        memory::worker_module(&deps)?,
        jobs::worker_module(jobs_deps.clone())?,
        git::worker_module(&deps)?,
        web::worker_module(&deps)?,
        tool_sources::worker_module(&deps)?,
        subagents::worker_module(&deps)?,
        scheduler::worker_module(&deps)?,
        filesystem::worker_module(&deps)?,
        blob::worker_module(&deps)?,
        message::worker_module(&deps)?,
        settings::worker_module(&deps)?,
        transcription::worker_module(&deps)?,
        auth::worker_module(&deps)?,
        worker_lifecycle::worker_module(worker_lifecycle_deps.clone())?,
        agent::worker_module(&deps)?,
        logs::worker_module(&deps)?,
        session::worker_module(&deps)?,
    ];
    modules.extend(model::worker_modules(&deps)?);
    validate_domain_composition(&modules)?;
    for module in &modules {
        validate_domain_stream_topics(module)?;
    }
    Ok(DomainComposition {
        modules,
        activation: DomainLifecycleActivation {
            jobs: jobs_deps,
            worker_lifecycle: worker_lifecycle_deps,
        },
    })
}

fn validate_domain_composition(modules: &[DomainWorkerModule]) -> EngineResult<()> {
    let mut function_ids = BTreeSet::new();
    for module in modules {
        for function in &module.functions {
            if function.definition.owner_worker != module.worker.id {
                return Err(EngineError::PolicyViolation(format!(
                    "function {} is owned by {} but composed under domain worker {}",
                    function.definition.id.as_str(),
                    function.definition.owner_worker.as_str(),
                    module.worker.id.as_str()
                )));
            }
            if !function_ids.insert(function.definition.id.as_str()) {
                return Err(EngineError::PolicyViolation(format!(
                    "duplicate canonical function id {} in domain composition",
                    function.definition.id.as_str()
                )));
            }
        }
    }
    Ok(())
}

fn validate_domain_stream_topics(module: &DomainWorkerModule) -> EngineResult<()> {
    let declared = module
        .stream_topics
        .iter()
        .copied()
        .collect::<BTreeSet<_>>();
    if declared.len() != module.stream_topics.len() {
        return Err(EngineError::PolicyViolation(format!(
            "domain worker {} declares duplicate stream topics",
            module.worker.id.as_str()
        )));
    }
    for topic in &declared {
        if topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(format!(
                "domain worker {} declares an empty stream topic",
                module.worker.id.as_str()
            )));
        }
        if !topic.contains('.') {
            return Err(EngineError::PolicyViolation(format!(
                "domain worker {} stream topic {topic} must use domain-scoped dotted form",
                module.worker.id.as_str()
            )));
        }
        if matches!(
            *topic,
            "catalog.changes" | "queue.lifecycle" | "resource.leases" | "compensation.records"
        ) {
            return Err(EngineError::PolicyViolation(format!(
                "domain worker {} cannot claim engine-owned stream topic {topic}",
                module.worker.id.as_str()
            )));
        }
    }

    for function in &module.functions {
        validate_function_stream_topics(module, function, &declared)?;
    }
    Ok(())
}

fn validate_function_stream_topics(
    module: &DomainWorkerModule,
    function: &DomainFunctionRegistration,
    declared: &BTreeSet<&'static str>,
) -> EngineResult<()> {
    let Some(topics) = function.definition.metadata.get("streamTopics") else {
        return Ok(());
    };
    let Some(topics) = topics.as_array() else {
        return Err(EngineError::PolicyViolation(format!(
            "function {} streamTopics metadata must be an array",
            function.definition.id.as_str()
        )));
    };
    for topic in topics {
        let Some(topic) = topic.as_str() else {
            return Err(EngineError::PolicyViolation(format!(
                "function {} streamTopics metadata contains a non-string topic",
                function.definition.id.as_str()
            )));
        };
        if !declared.contains(topic) {
            return Err(EngineError::PolicyViolation(format!(
                "function {} emits undeclared domain stream topic {topic} for worker {}",
                function.definition.id.as_str(),
                module.worker.id.as_str()
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use serde_json::json;
    use std::sync::Arc;

    use crate::engine::{
        ActorContext, ActorId, ActorKind, AuthorityGrantId, CausalContext, EffectClass,
        FunctionDefinition, FunctionId, FunctionQuery, InProcessFunctionHandler, Invocation,
        RUNTIME_METADATA_WORKING_DIRECTORY, TraceId, VisibilityScope, WorkerDefinition, WorkerId,
        WorkerKind,
    };

    #[derive(Debug)]
    struct NoopHandler;

    #[async_trait]
    impl InProcessFunctionHandler for NoopHandler {
        async fn invoke(
            &self,
            _invocation: Invocation,
        ) -> crate::engine::Result<serde_json::Value> {
            Ok(json!({}))
        }
    }

    fn test_module(
        declared_topics: &'static [&'static str],
        function_topics: Vec<&'static str>,
    ) -> DomainWorkerModule {
        let worker = WorkerDefinition::new(
            WorkerId::new("test").expect("worker id"),
            WorkerKind::InProcess,
            crate::engine::ActorId::new("system").expect("actor id"),
            AuthorityGrantId::new("engine-transport").expect("grant id"),
        )
        .with_namespace_claim("test");
        let mut definition = FunctionDefinition::new(
            FunctionId::new("test::op").expect("function id"),
            WorkerId::new("test").expect("worker id"),
            "test op",
            VisibilityScope::System,
            EffectClass::PureRead,
        );
        definition.metadata = json!({ "streamTopics": function_topics });
        DomainWorkerModule {
            worker,
            functions: vec![DomainFunctionRegistration {
                definition,
                handler: Arc::new(NoopHandler),
            }],
            stream_topics: declared_topics,
        }
    }

    #[test]
    fn stream_topic_validation_accepts_declared_domain_topics() {
        let module = test_module(&["test.events"], vec!["test.events"]);
        validate_domain_stream_topics(&module).expect("declared topic should pass");
    }

    #[test]
    fn stream_topic_validation_rejects_engine_owned_topics() {
        let module = test_module(&["resource.leases"], vec!["resource.leases"]);
        let Err(error) = validate_domain_stream_topics(&module) else {
            panic!("engine topic must fail");
        };
        assert!(error.to_string().contains("engine-owned stream topic"));
    }

    #[test]
    fn stream_topic_validation_rejects_unscoped_topics() {
        let module = test_module(&["events"], vec!["events"]);
        let Err(error) = validate_domain_stream_topics(&module) else {
            panic!("unscoped topic must fail");
        };
        assert!(error.to_string().contains("domain-scoped dotted form"));
    }

    #[test]
    fn stream_topic_validation_rejects_undeclared_function_topics() {
        let module = test_module(&["test.events"], vec!["other.events"]);
        let Err(error) = validate_domain_stream_topics(&module) else {
            panic!("undeclared topic must fail");
        };
        assert!(error.to_string().contains("undeclared domain stream topic"));
    }

    #[test]
    fn domain_composition_rejects_duplicate_function_ids() {
        let mut module = test_module(&[], vec![]);
        module.functions.push(module.functions[0].clone());

        let Err(error) = validate_domain_composition(&[module]) else {
            panic!("duplicate canonical function id must fail");
        };
        assert!(
            error
                .to_string()
                .contains("duplicate canonical function id")
        );
    }

    #[test]
    fn domain_composition_rejects_function_owner_drift() {
        let mut module = test_module(&[], vec![]);
        module.functions[0].definition.owner_worker =
            WorkerId::new("other").expect("valid wrong owner");

        let Err(error) = validate_domain_composition(&[module]) else {
            panic!("function owner drift must fail");
        };
        assert!(error.to_string().contains("composed under domain worker"));
    }

    #[tokio::test]
    async fn primitive_teardown_startup_catalog_excludes_deleted_product_domains() {
        let ctx = crate::shared::server::test_support::make_test_context();
        let functions = ctx
            .engine_host
            .discover(&FunctionQuery {
                actor: Some(system_actor()),
                include_internal: true,
                ..FunctionQuery::default()
            })
            .await;
        let function_ids = functions
            .iter()
            .map(|function| function.id.as_str().to_owned())
            .collect::<Vec<_>>();

        assert!(
            function_ids
                .iter()
                .any(|function_id| function_id == "capability::execute"),
            "primitive execute must stay registered: {function_ids:?}"
        );
        for expected in [
            "filesystem::apply_patch",
            "filesystem::diff",
            "filesystem::edit",
            "filesystem::find",
            "filesystem::glob",
            "filesystem::list",
            "filesystem::read",
            "filesystem::search_text",
            "filesystem::write",
            "git::diff",
            "git::stage",
            "git::status",
            "git::unstage",
            "memory::configure_policy",
            "memory::edit",
            "memory::inspect",
            "memory::list",
            "memory::migrate_export",
            "memory::migrate_import",
            "memory::record_prompt_trace",
            "memory::retain",
            "memory::status",
            "memory::tombstone",
        ] {
            assert!(
                function_ids
                    .iter()
                    .any(|function_id| function_id == expected),
                "approved restored function missing from startup catalog: {expected}"
            );
        }
        for forbidden_prefix in forbidden_startup_prefixes() {
            assert!(
                !function_ids
                    .iter()
                    .any(|function_id| function_id.starts_with(&forbidden_prefix)),
                "noncanonical startup function prefix {forbidden_prefix} registered in {function_ids:?}"
            );
        }
    }

    #[tokio::test]
    async fn primitive_execute_observes_without_registry_routing() {
        let ctx = crate::shared::server::test_support::make_test_context();
        let tempdir = tempfile::tempdir().expect("working directory");
        let actor_id = ActorId::new("agent:primitive-test").expect("actor id");
        let grant = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("grant::derive").expect("function id"),
                json!({
                    "parentGrantId": "agent-capability-runtime",
                    "subjectActorId": actor_id.as_str(),
                    "allowedCapabilities": ["capability::execute"],
                    "allowedNamespaces": ["__no_namespace_authority__"],
                    "allowedAuthorityScopes": ["capability.execute"],
                    "allowedResourceKinds": ["agent_state"],
                    "resourceSelectors": ["kind:agent_state"],
                    "fileRoots": [tempdir.path().display().to_string()],
                    "networkPolicy": "none",
                    "maxRisk": "medium",
                    "budget": {"remainingInvocations": 1},
                    "canDelegate": false,
                    "provenance": {"source": "registration-test", "operation": "observe"}
                }),
                CausalContext::new(
                    ActorId::new("system:registration-test").expect("actor id"),
                    ActorKind::System,
                    AuthorityGrantId::new("grant").expect("grant id"),
                    TraceId::generate(),
                )
                .with_scope("grant.write")
                .with_session_id("primitive-test")
                .with_idempotency_key("primitive-execute-observe-grant"),
            ))
            .await;
        assert_eq!(grant.error, None, "derive grant failed: {:?}", grant.error);
        let grant_id = AuthorityGrantId::new(
            grant.value.expect("grant value")["grant"]["grantId"]
                .as_str()
                .expect("grant id"),
        )
        .expect("grant id");
        let invocation = Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            json!({
                "operation": "observe",
                "input": "hello primitive loop"
            }),
            CausalContext::new(actor_id, ActorKind::Agent, grant_id, TraceId::generate())
                .with_scope("capability.execute")
                .with_session_id("primitive-test")
                .with_runtime_metadata(
                    RUNTIME_METADATA_WORKING_DIRECTORY,
                    tempdir.path().display().to_string(),
                )
                .with_idempotency_key("primitive-execute-observe"),
        );
        let result = ctx.engine_host.invoke(invocation).await;
        assert!(
            result.error.is_none(),
            "primitive execute returned engine error: {:?}",
            result.error
        );
        let value = result.value.expect("capability result value");
        assert_eq!(value["isError"], false, "{value}");
        assert_eq!(value["details"]["primitiveOperation"], "observe", "{value}");
        assert!(
            value["content"][0]["text"]
                .as_str()
                .is_some_and(|text| text.contains("hello primitive loop")),
            "{value}"
        );
        assert!(
            value["details"].get("bindingDecision").is_none(),
            "primitive execute must not route through capability registry: {value}"
        );
    }

    fn system_actor() -> ActorContext {
        ActorContext::new(
            ActorId::new("system:test").expect("actor id"),
            ActorKind::System,
            AuthorityGrantId::new("engine-system").expect("grant id"),
        )
    }

    fn forbidden_startup_prefixes() -> Vec<String> {
        let product_namespaces = vec![
            ["agent", "_", "briefing"].concat(),
            "browser".to_owned(),
            "cron".to_owned(),
            "display".to_owned(),
            "events".to_owned(),
            "import".to_owned(),
            "job".to_owned(),
            "mcp".to_owned(),
            "notifications".to_owned(),
            "plan".to_owned(),
            "process".to_owned(),
            "program".to_owned(),
            ["prompt", "_", "library"].concat(),
            "repo".to_owned(),
            "sandbox".to_owned(),
            ["self", "_", "extension"].concat(),
            ["sk", "ills"].concat(),
            "tree".to_owned(),
            ["voice", "_", "notes"].concat(),
            "web".to_owned(),
            ["work", "tree"].concat(),
        ];
        let mut prefixes = product_namespaces
            .into_iter()
            .map(|namespace| format!("{namespace}::"))
            .collect::<Vec<_>>();
        prefixes.extend([
            format!("agent::{}", "run_goal"),
            format!("agent::{}", "work_snapshot"),
            format!("agent::{}", ["ask", "_", "user"].concat()),
            format!("agent::{}", ["submit", "_", "answers"].concat()),
            format!("agent::spawn_{}", ["sub", "agent"].concat()),
            format!("agent::{}_{}", ["sub", "agent"].concat(), ""),
            format!("agent::cancel_{}", ["sub", "agent"].concat()),
            format!("worker::{}", "spawn"),
            format!("capability::{}", "search"),
            format!("capability::{}", "inspect"),
            format!("capability::{}", "status"),
            format!("capability::{}", "registry_snapshot"),
            format!("capability::{}", "binding_"),
            format!("capability::{}", "plugin_"),
            format!("capability::{}", ["con", "formance_"].concat()),
            format!("capability::{}", "policy_"),
            format!("capability::{}", "program_run_list"),
            format!("filesystem::{}", "read_file"),
            format!("filesystem::{}", "write_file"),
            format!("filesystem::{}", "edit_file"),
        ]);
        prefixes
    }
}
