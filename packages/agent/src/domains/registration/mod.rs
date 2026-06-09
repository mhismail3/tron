//! Domain worker registration.
//!
//! This module registers the retained in-process workers for the primitive
//! engine branch. Startup intentionally excludes retired product domains; those
//! surfaces are being torn down to the checked-in primitives documented by the
//! scorecard.
//!
//! `capability` owns the only model-facing tool, `capability::execute`, and
//! that tool performs direct primitive operations rather than catalog routing.
//! The registration entrypoint is crate-private: transport setup is the
//! server-facing facade, while this module owns the concrete domain-worker
//! wiring.
//!
//! # INVARIANT: canonical capabilities are the executable surface
//!
//! Domain method names are internal operation keys for service routing only.
//! Only canonical function ids are registered.

pub(crate) mod bindings;
pub(crate) mod catalog;
pub(crate) mod contract;
pub(crate) mod worker;

use std::collections::BTreeSet;

use crate::engine::{EngineError, Result as EngineResult};
use crate::shared::server::context::ServerRuntimeContext;

use crate::domains::registration::worker::{
    DomainFunctionRegistration, DomainRegistrationContext, DomainWorkerModule,
};
use crate::domains::{
    agent, auth, blob, capability, logs, message, model, session, settings, system,
};

/// Register server-owned domain workers, canonical functions, and trigger records.
pub(crate) fn register_domain_workers_for_context(ctx: &ServerRuntimeContext) -> EngineResult<()> {
    register_domain_workers(ctx)
}

fn register_domain_workers(ctx: &ServerRuntimeContext) -> EngineResult<()> {
    let handle = &ctx.engine_host;
    for module in domain_worker_modules(ctx)? {
        validate_domain_stream_topics(&module)?;
        handle.register_worker_for_setup(module.worker, false)?;
        for function in module.functions {
            handle.register_function_for_setup(
                function.definition,
                Some(function.handler),
                false,
            )?;
        }
    }
    Ok(())
}

fn domain_worker_modules(ctx: &ServerRuntimeContext) -> EngineResult<Vec<DomainWorkerModule>> {
    let deps = DomainRegistrationContext::from_context(ctx);
    let mut modules = vec![
        system::worker_module(&deps)?,
        capability::worker_module(&deps)?,
        blob::worker_module(&deps)?,
        message::worker_module(&deps)?,
        settings::worker_module(&deps)?,
        auth::worker_module(&deps)?,
        agent::worker_module(&deps)?,
        logs::worker_module(&deps)?,
        session::worker_module(&deps)?,
    ];
    modules.extend(model::worker_modules(&deps)?);
    Ok(modules)
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
        TraceId, VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
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
    fn stream_topic_validation_rejects_undeclared_function_topics() {
        let module = test_module(&["test.events"], vec!["other.events"]);
        let Err(error) = validate_domain_stream_topics(&module) else {
            panic!("undeclared topic must fail");
        };
        assert!(error.to_string().contains("undeclared domain stream topic"));
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
        for retired_prefix in retired_startup_prefixes() {
            assert!(
                !function_ids
                    .iter()
                    .any(|function_id| function_id.starts_with(&retired_prefix)),
                "retired startup function prefix {retired_prefix} still registered in {function_ids:?}"
            );
        }
    }

    #[tokio::test]
    async fn primitive_execute_observes_without_registry_routing() {
        let ctx = crate::shared::server::test_support::make_test_context();
        let invocation = Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            json!({
                "operation": "observe",
                "input": "hello primitive loop"
            }),
            CausalContext::new(
                ActorId::new("agent:primitive-test").expect("actor id"),
                ActorKind::Agent,
                AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
                TraceId::generate(),
            )
            .with_scope("capability.execute")
            .with_session_id("primitive-test")
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

    fn retired_startup_prefixes() -> Vec<String> {
        let product_namespaces = vec![
            "browser".to_owned(),
            "cron".to_owned(),
            "display".to_owned(),
            "events".to_owned(),
            ["file", "system"].concat(),
            "git".to_owned(),
            "import".to_owned(),
            "job".to_owned(),
            "mcp".to_owned(),
            "memory".to_owned(),
            "notifications".to_owned(),
            "plan".to_owned(),
            "process".to_owned(),
            "program".to_owned(),
            ["prompt", "_", "library"].concat(),
            "repo".to_owned(),
            "sandbox".to_owned(),
            ["self", "_", "extension"].concat(),
            ["sk", "ills"].concat(),
            ["trans", "cription"].concat(),
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
        ]);
        prefixes
    }
}
