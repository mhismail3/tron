//! Domain worker registration.
//!
//! This module registers canonical in-process domain workers, their functions,
//! hidden apply functions, tool functions, and trigger definitions. Transport
//! startup calls this module once; individual domain workers own the executable
//! behavior and metadata.
//!
//! Domain workers such as `skills`, `filesystem`, `events`, `notifications`, `plan`, `settings`,
//! `logs`, `prompt_library`, `model`, `session`, `context`, `job`, `agent`,
//! `git`, `worktree`, `auth`, `device`, `voice_notes`, `transcription`,
//! `browser`, `display`, `sandbox`, `mcp`, and `system` own executable
//! function contracts and behavior metadata. A separate `tool` worker registers
//! built-in agent tools as
//! canonical `tool::*` functions. Provider requests now resolve schemas from
//! the live catalog, so built-ins, engine meta-tools, and eligible MCP
//! capabilities are all surfaced through the same agent-facing capability
//! fabric instead of through a frozen `ToolRegistry` snapshot.
//! `engine_ws` trigger records capture public engine protocol messages.
//! `cron_schedule` trigger records capture scheduled automation fires.
//!
//! # INVARIANT: canonical capabilities are the executable surface
//!
//! Domain method names are internal operation keys for service routing only.
//! Only canonical function ids are registered.

use std::collections::BTreeSet;

use crate::engine::{EngineError, Result as EngineResult};
use crate::server::shared::context::ServerRuntimeContext;

use crate::server::domains::catalog;
use crate::server::domains::{DomainFunctionRegistration, DomainWorkerModule};

/// Register server-owned domain workers, canonical functions, and trigger records.
pub fn register_domain_workers_for_context(ctx: &ServerRuntimeContext) -> EngineResult<()> {
    register_domain_workers(ctx)?;
    let deps = crate::server::domains::DomainRegistrationContext::from_context(ctx);
    crate::server::domains::tools::register_builtin_tools_for_setup(&deps)?;
    Ok(())
}

fn register_domain_workers(ctx: &ServerRuntimeContext) -> EngineResult<()> {
    let handle = &ctx.engine_host;
    for module in crate::server::domains::all_worker_modules(ctx)? {
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
    handle.register_trigger_type_for_setup(catalog::cron_schedule_trigger_type()?, false)?;
    let deps = crate::server::domains::DomainRegistrationContext::from_context(ctx);
    let cron_deps = crate::server::domains::cron::Deps::from_engine(&deps);
    crate::server::domains::cron::project_all_cron_triggers_for_setup(handle, &cron_deps)?;
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
        if matches!(
            *topic,
            "catalog.changes"
                | "queue.lifecycle"
                | "resource.leases"
                | "approval.pending"
                | "approval.resolved"
                | "compensation.records"
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
        AuthorityGrantId, EffectClass, FunctionDefinition, FunctionId, InProcessFunctionHandler,
        Invocation, VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
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
}
