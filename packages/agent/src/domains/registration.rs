//! Domain worker registration.
//!
//! This module registers canonical in-process domain workers, their functions,
//! hidden apply functions and trigger definitions. Transport
//! startup calls this module once; individual domain workers own the executable
//! behavior and metadata.
//!
//! Domain workers such as `capability`, `skills`, `filesystem`, `events`, `notifications`, `plan`, `settings`,
//! `logs`, `prompt_library`, `model`, `session`, `context`, `job`, `agent`,
//! `git`, `worktree`, `auth`, `device`, `voice_notes`, `transcription`,
//! `browser`, `display`, `sandbox`, `mcp`, `process`, `web`, and `system` own
//! executable function contracts and behavior metadata. Provider requests now
//! resolve schemas from the live catalog, so first-party, MCP, sandbox, and
//! external capabilities are all surfaced through the same agent-facing
//! capability fabric.
//! `capability` is the collapsed model-facing harness worker: providers see
//! only `search`, `inspect`, and `execute`, and those primitives route back
//! into live worker-owned catalog entries. `engine_ws` trigger records capture public engine protocol messages.
//! `cron_schedule` trigger records capture scheduled automation fires.
//!
//! # INVARIANT: canonical capabilities are the executable surface
//!
//! Domain method names are internal operation keys for service routing only.
//! Only canonical function ids are registered.

use std::collections::BTreeSet;

use crate::engine::{EngineError, Result as EngineResult};
use crate::shared::server::context::ServerRuntimeContext;

use crate::domains::catalog;
use crate::domains::worker::{
    DomainFunctionRegistration, DomainRegistrationContext, DomainWorkerModule,
};
use crate::domains::{
    agent, auth, blob, browser, capability, context, cron, device, display, events, filesystem,
    git, import, job, logs, mcp, memory, message, model, notifications, plan, process, program,
    prompt_library, repo, sandbox, session, settings, skills, system, transcription, tree,
    voice_notes, web, worktree,
};

/// Register server-owned domain workers, canonical functions, and trigger records.
pub fn register_domain_workers_for_context(ctx: &ServerRuntimeContext) -> EngineResult<()> {
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
    handle.register_trigger_type_for_setup(catalog::cron_schedule_trigger_type()?, false)?;
    let deps = DomainRegistrationContext::from_context(ctx);
    let cron_deps = cron::Deps::from_engine(&deps);
    cron::project_all_cron_triggers_for_setup(handle, &cron_deps)?;
    Ok(())
}

fn domain_worker_modules(ctx: &ServerRuntimeContext) -> EngineResult<Vec<DomainWorkerModule>> {
    let deps = DomainRegistrationContext::from_context(ctx);
    let mut modules = vec![
        system::worker_module(&deps)?,
        capability::worker_module(&deps)?,
        blob::worker_module(&deps)?,
        message::worker_module(&deps)?,
        cron::worker_module(&deps)?,
        settings::worker_module(&deps)?,
        auth::worker_module(&deps)?,
        skills::worker_module(&deps)?,
        agent::worker_module(&deps)?,
        mcp::worker_module(&deps)?,
        logs::worker_module(&deps)?,
        memory::worker_module(&deps)?,
        events::worker_module(&deps)?,
        filesystem::worker_module(&deps)?,
        session::worker_module(&deps)?,
        context::worker_module(&deps)?,
        job::worker_module(&deps)?,
        notifications::worker_module(&deps)?,
        plan::worker_module(&deps)?,
        process::worker_module(&deps)?,
        program::worker_module(&deps)?,
        prompt_library::worker_module(&deps)?,
        tree::worker_module(&deps)?,
        repo::worker_module(&deps)?,
        import::worker_module(&deps)?,
        browser::worker_module(&deps)?,
        display::worker_module(&deps)?,
        device::worker_module(&deps)?,
        transcription::worker_module(&deps)?,
        voice_notes::worker_module(&deps)?,
        web::worker_module(&deps)?,
        sandbox::worker_module(&deps)?,
        git::worker_module(&deps)?,
        worktree::worker_module(&deps)?,
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
