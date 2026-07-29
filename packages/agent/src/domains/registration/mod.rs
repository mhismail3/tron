//! Domain function composition.
//!
//! This module registers the small trusted-local worker-first kernel and the
//! product infrastructure still needed by authenticated clients and sessions.
//! Persistent behavior is registered dynamically from filesystem-owned worker
//! bundles, while this module composes only executable source-owned functions.
//! The complete production composition validates canonical identity uniqueness
//! before either registration path mutates the engine catalog. The worker runtime returns one
//! activation token so transport setup starts its lifecycle observer only after
//! registration. That observer always runs and keeps worker dispatch, dynamic
//! tool projection, schedules, events, and resident services live.
//!
//! # INVARIANT: canonical functions are the executable surface
//!
//! Domain method names are internal operation keys for service routing only.
//! Only canonical function ids are registered. Every handler binding is owned
//! by a domain contract; composition has no hidden-operation exceptions.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `contract` | Build the exact engine definition owned by each domain. |
//! | `bindings` | Validate one-to-one handler coverage and wrap local handlers. |
//! | `composition` | Narrow startup dependencies and carry executable registrations. |

pub(crate) mod bindings;
pub(crate) mod composition;
pub(crate) mod contract;

use std::collections::BTreeSet;

use crate::engine::{EngineError, Result as EngineResult};
use crate::shared::server::context::ServerRuntimeContext;

use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};
use crate::domains::{agent, auth, filesystem, model, product, session, settings, worker_kernel};

#[must_use = "activate after transport-trigger registration"]
pub(crate) struct DomainLifecycleActivation {
    worker_kernel: std::sync::Arc<worker_kernel::WorkerRuntime>,
    shutdown_coordinator:
        Option<std::sync::Arc<crate::app::lifecycle::shutdown::ShutdownCoordinator>>,
}

impl DomainLifecycleActivation {
    #[cfg(test)]
    pub(crate) fn into_worker_kernel_without_activation(
        self,
    ) -> std::sync::Arc<worker_kernel::WorkerRuntime> {
        self.worker_kernel
    }

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
    functions: Vec<DomainFunctionRegistration>,
    engine_functions: Vec<DomainFunctionRegistration>,
    activation: DomainLifecycleActivation,
}

/// Register server-owned canonical functions.
pub(crate) fn register_domains_for_context(
    ctx: &ServerRuntimeContext,
) -> EngineResult<DomainLifecycleActivation> {
    let DomainComposition {
        functions,
        engine_functions,
        activation,
    } = compose_domains(ctx)?;
    let handle = &ctx.engine_host;
    for function in functions {
        handle.register_function_for_setup(function.definition, function.handler)?;
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
        functions,
        engine_functions,
        activation,
    } = compose_domains(ctx)?;
    let handle = &ctx.engine_host;
    for function in functions {
        handle
            .register_function(function.definition, function.handler)
            .await?;
    }
    for function in engine_functions {
        handle
            .register_function(function.definition, function.handler)
            .await?;
    }
    Ok(activation)
}

fn compose_domains(ctx: &ServerRuntimeContext) -> EngineResult<DomainComposition> {
    let deps = DomainRegistrationContext::from_context(ctx);
    let worker_kernel_registration = worker_kernel::registration(&deps)?;
    let worker_kernel_runtime = worker_kernel_registration.runtime.clone();
    let engine_functions = worker_kernel_registration.engine_functions;
    let mut functions = Vec::new();
    functions.extend(product::system::function_registrations(&deps)?);
    functions.extend(worker_kernel_registration.functions);
    functions.extend(filesystem::function_registrations(&deps)?);
    functions.extend(product::blob::function_registrations(&deps)?);
    functions.extend(product::message::function_registrations(&deps)?);
    functions.extend(settings::function_registrations(&deps)?);
    functions.extend(auth::function_registrations(&deps)?);
    functions.extend(agent::function_registrations(&deps)?);
    functions.extend(product::logs::function_registrations(&deps)?);
    functions.extend(session::function_registrations(&deps)?);
    functions.extend(model::function_registrations(&deps)?);
    validate_domain_composition(&functions)?;
    validate_engine_extension_functions(&engine_functions)?;
    Ok(DomainComposition {
        functions,
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

fn validate_domain_composition(functions: &[DomainFunctionRegistration]) -> EngineResult<()> {
    let mut function_ids = BTreeSet::new();
    for function in functions {
        if !function_ids.insert(function.definition.id.as_str()) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate canonical function id {} in domain composition",
                function.definition.id.as_str()
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
        ActorContext, ActorId, ActorKind, CausalContext, EffectClass, FunctionDefinition,
        FunctionId, FunctionVisibility, InProcessFunctionHandler, Invocation, TraceId, WorkerId,
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

    fn test_function() -> DomainFunctionRegistration {
        let definition = FunctionDefinition::new(
            FunctionId::new("test::op").expect("function id"),
            WorkerId::new("test").expect("worker id"),
            "test op",
            FunctionVisibility::Public,
            EffectClass::PureRead,
        );
        DomainFunctionRegistration {
            definition,
            handler: Arc::new(NoopHandler),
        }
    }

    #[test]
    fn domain_composition_rejects_duplicate_function_ids() {
        let function = test_function();

        let Err(error) = validate_domain_composition(&[function.clone(), function]) else {
            panic!("duplicate canonical function id must fail");
        };
        assert!(
            error
                .to_string()
                .contains("duplicate canonical function id")
        );
    }

    #[tokio::test]
    async fn startup_catalog_contains_worker_first_fixed_functions() {
        let ctx = crate::shared::server::test_support::make_test_context();
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
            "session::set_title",
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
        let ctx = crate::shared::server::test_support::make_test_context();
        let invocation = Invocation::new_sync(
            FunctionId::new("worker_kernel::list").expect("function id"),
            json!({}),
            CausalContext::new(
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
        let ctx = crate::shared::server::test_support::make_test_context();
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
        let ctx = crate::shared::server::test_support::make_test_context();
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
        let fixed_tools = value["fixedTools"]
            .as_array()
            .expect("fixed tool inventory");
        assert_eq!(fixed_tools.len(), 29);
        assert!(
            fixed_tools.iter().any(|tool| {
                tool["modelName"] == "session_set_title" && tool["exposed"] == false
            })
        );
        assert_eq!(
            fixed_tools
                .iter()
                .filter(|tool| tool["audience"] == "ordinary")
                .count(),
            15
        );
        assert!(
            fixed_tools
                .iter()
                .any(|tool| tool["modelName"] == "worker_result_read")
        );
        assert!(value["surface"]["catalogRevision"].is_u64());
        assert_eq!(value["surface"]["fixedToolCount"], 15);
        assert!(value["surface"]["surfaceHash"].is_string());
        assert!(value["surface"]["availableWorkers"].is_array());
        assert!(value["surface"].get("tools").is_none());

        let renamed = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("engine::surface_snapshot").expect("surface function id"),
                json!({"relevanceQuery":"please rename this conversation"}),
                trusted_local_context("engine-surface-rename"),
            ))
            .await
            .value
            .expect("rename surface snapshot");
        assert_eq!(renamed["surface"]["fixedToolCount"], 16);
        assert!(renamed["fixedTools"].as_array().is_some_and(|tools| {
            tools.iter().any(|tool| {
                tool["modelName"] == "session_set_title"
                    && tool["functionId"] == "session::set_title"
                    && tool["audience"] == "conditional"
                    && tool["exposed"] == true
            })
        }));
        assert!(value["workers"].is_array());

        let surface = crate::domains::agent::r#loop::surface::resolve_provider_primitive_surface(
            &ctx.engine_host,
            "engine-surface-snapshot",
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

    fn trusted_local_context(trace: &str) -> CausalContext {
        CausalContext::new(
            ActorId::new("agent:worker-first-test").expect("actor id"),
            ActorKind::Agent,
            TraceId::new(trace).expect("trace id"),
        )
        .with_session_id("worker-first-test")
        .with_idempotency_key(trace)
    }

    fn system_actor() -> ActorContext {
        ActorContext::new(
            ActorId::new("system:test").expect("actor id"),
            ActorKind::System,
        )
    }
}
