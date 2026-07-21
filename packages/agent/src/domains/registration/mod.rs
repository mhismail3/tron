//! Domain function composition.
//!
//! This module registers the small trusted-local worker-first kernel and the
//! product infrastructure still needed by authenticated clients and sessions.
//! Persistent behavior is registered dynamically from filesystem-owned worker
//! bundles; there is no module manifest, proposal, binding, scheduler, legacy
//! worker-lifecycle, or `capability::execute` registration plane.
//! The complete production composition validates function ownership,
//! canonical identity uniqueness, and stream-topic boundaries before either
//! registration path mutates the engine catalog. The worker runtime returns one
//! activation token so transport setup starts its lifecycle observer only after
//! registration. That observer always runs; the editable autonomous-worker
//! setting controls dispatch and the provider tool surface live rather than
//! deciding whether the lifecycle exists at boot.
//!
//! # INVARIANT: canonical functions are the executable surface
//!
//! Domain method names are internal operation keys for service routing only.
//! Only canonical function ids are registered. Every handler binding is owned
//! by a domain contract; composition has no hidden-operation exceptions.

pub(crate) mod bindings;
pub(crate) mod catalog;
pub(crate) mod contract;
pub(crate) mod module;

use std::collections::BTreeSet;

use crate::engine::{EngineError, Result as EngineResult};
use crate::shared::server::context::ServerRuntimeContext;

use crate::domains::registration::module::{
    DomainFunctionRegistration, DomainModule, DomainRegistrationContext,
};
use crate::domains::{
    agent, auth, blob, filesystem, logs, message, model, session, settings, system, worker_kernel,
};

#[must_use = "activate after transport-trigger registration"]
pub(crate) struct DomainLifecycleActivation {
    worker_kernel: std::sync::Arc<worker_kernel::WorkerRuntime>,
    shutdown_coordinator:
        Option<std::sync::Arc<crate::app::lifecycle::shutdown::ShutdownCoordinator>>,
}

impl DomainLifecycleActivation {
    pub(crate) fn activate(self) {
        let shutdown_coordinator = self.shutdown_coordinator;
        let runtime = self.worker_kernel;
        let cancellation = shutdown_coordinator
            .as_ref()
            .map_or_else(tokio_util::sync::CancellationToken::new, |shutdown| {
                shutdown.token()
            });
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let task = handle.spawn(async move {
                runtime.activate(cancellation).await;
            });
            if let Some(shutdown) = shutdown_coordinator {
                shutdown.register_task(task);
            }
        }
    }
}

struct DomainComposition {
    modules: Vec<DomainModule>,
    engine_functions: Vec<DomainFunctionRegistration>,
    activation: DomainLifecycleActivation,
}

/// Register server-owned canonical functions.
pub(crate) fn register_domains_for_context(
    ctx: &ServerRuntimeContext,
) -> EngineResult<DomainLifecycleActivation> {
    let DomainComposition {
        modules,
        engine_functions,
        activation,
    } = domain_modules(ctx)?;
    let handle = &ctx.engine_host;
    for module in modules {
        for function in module.functions {
            handle.register_function_for_setup(function.definition, function.handler)?;
        }
    }
    for function in engine_functions {
        handle.register_function_for_setup(function.definition, function.handler)?;
    }
    Ok(activation)
}

/// Register server-owned canonical functions during async server startup.
pub(crate) async fn register_domains_for_runtime_context(
    ctx: &ServerRuntimeContext,
) -> EngineResult<DomainLifecycleActivation> {
    let DomainComposition {
        modules,
        engine_functions,
        activation,
    } = domain_modules(ctx)?;
    let handle = &ctx.engine_host;
    for module in modules {
        for function in module.functions {
            handle
                .register_function(function.definition, function.handler)
                .await?;
        }
    }
    for function in engine_functions {
        handle
            .register_function(function.definition, function.handler)
            .await?;
    }
    Ok(activation)
}

fn domain_modules(ctx: &ServerRuntimeContext) -> EngineResult<DomainComposition> {
    let deps = DomainRegistrationContext::from_context(ctx);
    let worker_kernel_registration = worker_kernel::registration(&deps)?;
    let worker_kernel_runtime = worker_kernel_registration.runtime.clone();
    let engine_functions = worker_kernel_registration.engine_functions;
    let mut modules = vec![
        system::function_module(&deps)?,
        worker_kernel_registration.module,
        filesystem::function_module(&deps)?,
        blob::function_module(&deps)?,
        message::function_module(&deps)?,
        settings::function_module(&deps)?,
        auth::function_module(&deps)?,
        agent::function_module(&deps)?,
        logs::function_module(&deps)?,
        session::function_module(&deps)?,
    ];
    modules.extend(model::function_modules(&deps)?);
    validate_domain_composition(&modules)?;
    validate_engine_extension_functions(&engine_functions)?;
    for module in &modules {
        validate_domain_stream_topics(module)?;
    }
    Ok(DomainComposition {
        modules,
        engine_functions,
        activation: DomainLifecycleActivation {
            worker_kernel: worker_kernel_runtime,
            shutdown_coordinator: ctx.shutdown_coordinator.clone(),
        },
    })
}

fn validate_engine_extension_functions(
    functions: &[DomainFunctionRegistration],
) -> EngineResult<()> {
    let mut function_ids = BTreeSet::new();
    for function in functions {
        if function.definition.id.namespace() != "engine"
            || function.definition.owner_worker.as_str() != "engine"
        {
            return Err(EngineError::PolicyViolation(format!(
                "engine extension {} must use the reserved engine owner",
                function.definition.id.as_str()
            )));
        }
        if !function_ids.insert(function.definition.id.as_str()) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate engine extension function id {}",
                function.definition.id.as_str()
            )));
        }
    }
    Ok(())
}

fn validate_domain_composition(modules: &[DomainModule]) -> EngineResult<()> {
    let mut function_ids = BTreeSet::new();
    for module in modules {
        for function in &module.functions {
            if function.definition.owner_worker != module.owner {
                return Err(EngineError::PolicyViolation(format!(
                    "function {} is owned by {} but composed under domain component {}",
                    function.definition.id.as_str(),
                    function.definition.owner_worker.as_str(),
                    module.owner.as_str()
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

fn validate_domain_stream_topics(module: &DomainModule) -> EngineResult<()> {
    let declared = module
        .stream_topics
        .iter()
        .copied()
        .collect::<BTreeSet<_>>();
    if declared.len() != module.stream_topics.len() {
        return Err(EngineError::PolicyViolation(format!(
            "domain component {} declares duplicate stream topics",
            module.owner.as_str()
        )));
    }
    for topic in &declared {
        if topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(format!(
                "domain component {} declares an empty stream topic",
                module.owner.as_str()
            )));
        }
        if !topic.contains('.') {
            return Err(EngineError::PolicyViolation(format!(
                "domain component {} stream topic {topic} must use domain-scoped dotted form",
                module.owner.as_str()
            )));
        }
        if matches!(*topic, "catalog.changes" | "queue.lifecycle") {
            return Err(EngineError::PolicyViolation(format!(
                "domain component {} cannot claim engine-owned stream topic {topic}",
                module.owner.as_str()
            )));
        }
    }

    for function in &module.functions {
        validate_function_stream_topics(module, function, &declared)?;
    }
    Ok(())
}

fn validate_function_stream_topics(
    module: &DomainModule,
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
                "function {} emits undeclared domain stream topic {topic} for component {}",
                function.definition.id.as_str(),
                module.owner.as_str()
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
    use std::time::Duration;

    use crate::engine::{
        ActorContext, ActorId, ActorKind, CausalContext, EffectClass, FunctionDefinition,
        FunctionId, InProcessFunctionHandler, Invocation, TraceId, VisibilityScope, WorkerId,
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
    ) -> DomainModule {
        let mut definition = FunctionDefinition::new(
            FunctionId::new("test::op").expect("function id"),
            WorkerId::new("test").expect("worker id"),
            "test op",
            VisibilityScope::System,
            EffectClass::PureRead,
        );
        definition.metadata = json!({ "streamTopics": function_topics });
        DomainModule {
            owner: WorkerId::new("test").expect("worker id"),
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
    fn stream_topic_validation_rejects_active_engine_owned_topics() {
        let module = test_module(&["catalog.changes"], vec!["catalog.changes"]);
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
        assert!(
            error
                .to_string()
                .contains("composed under domain component")
        );
    }

    #[tokio::test]
    async fn startup_catalog_contains_worker_first_fixed_functions() {
        let ctx = crate::shared::server::test_support::make_test_context_with_autonomous_workers();
        let functions = ctx.engine_host.visible_functions(&system_actor()).await;
        let function_ids = functions
            .iter()
            .map(|function| function.id.as_str().to_owned())
            .collect::<Vec<_>>();

        for expected in [
            "worker_kernel::upsert",
            "worker_kernel::discover",
            "worker_kernel::list",
            "worker_kernel::inspect",
            "worker_kernel::invoke",
            "worker_kernel::stop",
            "worker_kernel::disable",
            "worker_kernel::rollback",
            "worker_kernel::stop_all",
            "worker_kernel::core_proposal_create",
            "worker_kernel::core_proposal_apply",
            "filesystem::create_dir",
            "filesystem::get_home",
            "filesystem::list_dir",
        ] {
            assert!(
                function_ids
                    .iter()
                    .any(|function_id| function_id == expected),
                "worker-first fixed function missing from startup catalog: {expected}"
            );
        }
    }

    #[tokio::test]
    async fn trusted_local_kernel_invocation_records_actor_and_trace_without_grant_plane() {
        let ctx = crate::shared::server::test_support::make_test_context_with_autonomous_workers();
        let invocation = Invocation::new_sync(
            FunctionId::new("worker_kernel::list").expect("function id"),
            json!({}),
            CausalContext::trusted_local(
                ActorId::new("agent:worker-first-test").expect("actor id"),
                ActorKind::Agent,
                TraceId::generate(),
            )
            .with_session_id("worker-first-test"),
        );
        let invocation_id = invocation.id.clone();
        let actor_id = invocation.causal_context.actor_id.clone();

        let result = ctx.engine_host.invoke(invocation).await;

        assert_eq!(result.error, None, "direct list failed: {:?}", result.error);
        assert!(result.value.expect("list value")["workers"].is_array());
        let records = ctx
            .engine_host
            .replay_snapshot("worker-first-test")
            .await
            .expect("replay snapshot")
            .invocations;
        assert!(
            records
                .iter()
                .any(|record| record.invocation_id == invocation_id
                    && record.actor_id == actor_id
                    && record.invocation_id == result.invocation_id),
            "trusted-local invocation must persist actor and invocation identity"
        );
    }

    #[tokio::test]
    async fn host_write_edit_and_read_are_atomic_bounded_direct_primitives() {
        let ctx = crate::shared::server::test_support::make_test_context_with_autonomous_workers();
        let root = tempfile::tempdir().expect("host primitive temp root");
        let path = root.path().join("value.txt");
        let write = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::filesystem_write").expect("write function"),
                json!({"path":path,"content":"alpha alpha","expectedSha256":"absent"}),
                trusted_local_context("host-write-direct"),
            ))
            .await;
        assert_eq!(write.error, None, "direct write failed: {:?}", write.error);
        let write = write.value.expect("write response");
        assert_eq!(write["changed"], true);
        let checksum = write["sha256"].as_str().expect("write checksum");

        let edit = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::filesystem_edit").expect("edit function"),
                json!({
                    "path":path,
                    "expectedSha256":checksum,
                    "replacements":[{"oldText":"alpha","newText":"beta","expectedOccurrences":2}]
                }),
                trusted_local_context("host-edit-direct"),
            ))
            .await;
        assert_eq!(edit.error, None, "direct edit failed: {:?}", edit.error);
        assert_eq!(edit.value.as_ref().unwrap()["replacementsApplied"], 2);

        let read = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::filesystem_read").expect("read function"),
                json!({"path":path,"maxBytes":5}),
                trusted_local_context("host-read-direct"),
            ))
            .await;
        assert_eq!(read.error, None, "direct read failed: {:?}", read.error);
        let read = read.value.expect("read response");
        assert_eq!(read["content"], "beta ");
        assert_eq!(read["truncated"], true);

        let stale = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::filesystem_edit").expect("edit function"),
                json!({
                    "path":path,
                    "expectedSha256":checksum,
                    "replacements":[{"oldText":"beta","newText":"lost","expectedOccurrences":2}]
                }),
                trusted_local_context("host-edit-stale"),
            ))
            .await;
        assert!(stale.error.is_some());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "beta beta");
    }

    #[tokio::test]
    async fn engine_surface_snapshot_is_invocable_but_not_model_visible() {
        let ctx = crate::shared::server::test_support::make_test_context_with_autonomous_workers();
        let result = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("engine::surface_snapshot").expect("surface function id"),
                json!({"relevanceQuery":"persistent workers"}),
                trusted_local_context("engine-surface-snapshot"),
            ))
            .await;
        assert_eq!(
            result.error, None,
            "engine surface snapshot failed: {:?}",
            result.error
        );
        let value = result.value.expect("surface snapshot value");
        assert_eq!(value["format"], 1);
        assert_eq!(value["autonomousWorkers"], true);
        assert_eq!(
            value["coreComponents"]
                .as_array()
                .expect("core component inventory")
                .len(),
            8
        );
        let fixed_tools = value["fixedTools"]
            .as_array()
            .expect("fixed tool inventory");
        assert_eq!(fixed_tools.len(), 27);
        assert!(fixed_tools.iter().all(|tool| tool["exposed"] == true));
        assert_eq!(
            fixed_tools
                .iter()
                .filter(|tool| tool["primitiveGroup"] == "host")
                .count(),
            7
        );
        assert!(value["surface"]["catalogRevision"].is_u64());
        assert_eq!(value["surface"]["fixedToolCount"], 27);
        assert!(value["surface"]["surfaceHash"].is_string());
        assert!(value["surface"]["availableWorkers"].is_array());
        assert!(value["workers"].is_array());

        let surface =
            crate::domains::agent::r#loop::primitive_surface::resolve_provider_primitive_surface(
                &ctx.engine_host,
                "engine-surface-snapshot",
                None,
            )
            .await
            .expect("provider surface");
        assert!(
            !surface
                .targets_by_name
                .contains_key("engine_surface_snapshot")
        );
        assert!(
            surface
                .snapshot
                .tools
                .iter()
                .all(|tool| tool.function_id != "engine::surface_snapshot")
        );
    }

    #[tokio::test]
    async fn engine_surface_snapshot_keeps_fixed_inventory_visible_when_autonomy_is_off() {
        let ctx = crate::shared::server::test_support::make_test_context();
        let result = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("engine::surface_snapshot").expect("surface function id"),
                json!({}),
                trusted_local_context("engine-surface-snapshot-disabled"),
            ))
            .await;
        assert_eq!(
            result.error, None,
            "disabled engine surface snapshot failed: {:?}",
            result.error
        );
        let value = result.value.expect("disabled surface snapshot value");
        assert_eq!(value["autonomousWorkers"], false);
        let fixed_tools = value["fixedTools"]
            .as_array()
            .expect("fixed tool inventory");
        assert_eq!(fixed_tools.len(), 27);
        assert!(fixed_tools.iter().all(|tool| tool["exposed"] == false));
        assert_eq!(value["surface"]["fixedToolCount"], 0);
    }

    #[tokio::test]
    async fn autonomous_worker_setting_reconfigures_live_tools_without_restart() {
        let ctx = crate::shared::server::test_support::make_test_context();
        assert_provider_tools(&ctx, &[], &["worker_upsert"]).await;
        let initial_list = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::list").expect("list function id"),
                json!({}),
                trusted_local_context("live-autonomy-initial-list"),
            ))
            .await;
        assert_eq!(
            initial_list.error, None,
            "authenticated operational reads must remain available while autonomy is off"
        );
        set_autonomous_workers(&ctx, true);
        assert_provider_tools(&ctx, &["worker_upsert"], &[]).await;

        let upsert = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::upsert").expect("upsert function id"),
                json!({
                    "bundle": {
                        "schemaVersion": "tron.worker_bundle.v1",
                        "workerId": "live-autonomy-toggle",
                        "name": "Live Autonomy Toggle",
                        "description": "Echo typed input to prove live profile autonomy transitions.",
                        "toolName": "worker_live_autonomy_toggle",
                        "inputSchema": {
                            "type": "object",
                            "required": ["value"],
                            "properties": {"value": {"type": "integer"}}
                        },
                        "outputSchema": {
                            "type": "object",
                            "required": ["value"],
                            "properties": {"value": {"type": "integer"}}
                        },
                        "runner": {"kind": "command", "command": ["sh", "-c", "cat"]},
                        "triggers": [{"kind": "manual", "id": "manual"}],
                        "smokeTests": [{"command": ["sh", "-c", "exit 0"], "timeoutSeconds": 5}],
                        "healthChecks": [{"command": ["sh", "-c", "exit 0"], "timeoutSeconds": 5}],
                        "provenance": [{"source": "test:live-autonomy-toggle"}]
                    }
                }),
                trusted_local_context("live-autonomy-toggle-upsert"),
            ))
            .await;
        assert_eq!(
            upsert.error, None,
            "worker upsert failed: {:?}",
            upsert.error
        );
        assert_provider_tools(&ctx, &["worker_live_autonomy_toggle"], &[]).await;

        set_autonomous_workers(&ctx, false);
        assert_provider_tools(&ctx, &[], &["worker_upsert", "worker_live_autonomy_toggle"]).await;
        let blocked_invoke = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::invoke").expect("invoke function id"),
                json!({
                    "workerId":"live-autonomy-toggle",
                    "input":{"value":7},
                    "idempotencyKey":"live-autonomy-blocked-invoke"
                }),
                trusted_local_context("live-autonomy-blocked-invoke"),
            ))
            .await;
        assert!(
            blocked_invoke.error.as_ref().is_some_and(|error| error
                .to_string()
                .contains("autonomous workers are disabled")),
            "worker execution must remain blocked while autonomy is off: {blocked_invoke:?}"
        );
        for (operation, trace) in [
            ("disable", "live-autonomy-console-disable"),
            ("enable", "live-autonomy-console-enable"),
        ] {
            let result = ctx
                .engine_host
                .invoke(Invocation::new_sync(
                    FunctionId::new(format!("worker_kernel::{operation}"))
                        .expect("management function id"),
                    json!({"workerId":"live-autonomy-toggle"}),
                    trusted_local_context(trace),
                ))
                .await;
            assert_eq!(
                result.error, None,
                "authenticated console management {operation} failed while autonomy was off: {:?}",
                result.error
            );
        }
        assert_provider_tools(&ctx, &[], &["worker_upsert", "worker_live_autonomy_toggle"]).await;

        set_autonomous_workers(&ctx, true);
        assert_provider_tools(&ctx, &["worker_upsert", "worker_live_autonomy_toggle"], &[]).await;
        let invoked = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::dynamic_live-autonomy-toggle")
                    .expect("dynamic function id"),
                json!({"value": 7}),
                trusted_local_context("live-autonomy-toggle-invoke"),
            ))
            .await;
        assert_eq!(
            invoked.error, None,
            "dynamic invoke failed: {:?}",
            invoked.error
        );
        assert_eq!(invoked.value, Some(json!({"value": 7})));

        set_autonomous_workers(&ctx, false);
    }

    fn set_autonomous_workers(ctx: &ServerRuntimeContext, enabled: bool) {
        crate::domains::settings::config::SettingsStore::new(&ctx.settings_path)
            .update(json!({"autonomousWorkers": enabled}))
            .expect("persist autonomous worker setting");
        ctx.settings_runtime
            .reload_now("live autonomous worker setting test")
            .expect("reload autonomous worker setting");
    }

    fn trusted_local_context(trace: &str) -> CausalContext {
        CausalContext::trusted_local(
            ActorId::new("agent:live-autonomy-toggle-test").expect("actor id"),
            ActorKind::Agent,
            TraceId::new(trace).expect("trace id"),
        )
        .with_session_id("live-autonomy-toggle-test")
        .with_idempotency_key(trace)
    }

    async fn assert_provider_tools(ctx: &ServerRuntimeContext, present: &[&str], absent: &[&str]) {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let surface = crate::domains::agent::r#loop::primitive_surface::resolve_provider_primitive_surface(
                    &ctx.engine_host,
                    "live-autonomy-toggle-test",
                    None,
                )
                .await
                .expect("resolve provider surface");
                let all_present = present
                    .iter()
                    .all(|name| surface.targets_by_name.contains_key(*name));
                let all_absent = absent
                    .iter()
                    .all(|name| !surface.targets_by_name.contains_key(*name));
                if all_present && all_absent {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap_or_else(|_| {
            panic!(
                "provider tool surface did not converge; expected present={present:?}, absent={absent:?}"
            )
        });
    }

    fn system_actor() -> ActorContext {
        ActorContext::new(
            ActorId::new("system:test").expect("actor id"),
            ActorKind::System,
        )
    }
}
