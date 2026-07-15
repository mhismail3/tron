//! Thin startup entrypoint for server-owned engine domain registration.
//!
//! Transport setup delegates to `domains::registration` so the client
//! protocol layer does not know individual domain workers, hidden apply
//! functions, or capability worker internals. Domain lifecycle tasks activate
//! only after both domain and transport-trigger registration succeed.

use crate::engine::Result as EngineResult;
use crate::shared::server::context::ServerRuntimeContext;

/// Register server-owned domain workers, canonical functions, and trigger types
/// for single-threaded setup/test contexts.
pub fn register_server_domains_for_context(ctx: &ServerRuntimeContext) -> EngineResult<()> {
    let activation = crate::domains::registration::register_domain_workers_for_context(ctx)?;
    crate::transport::engine::contracts::register_engine_transport_triggers_for_context(ctx)?;
    activation.activate();
    Ok(())
}

/// Register server-owned domain workers, canonical functions, and trigger types
/// during async server startup.
pub async fn register_server_domains_for_runtime_context(
    ctx: &ServerRuntimeContext,
) -> EngineResult<()> {
    let activation =
        crate::domains::registration::register_domain_workers_for_runtime_context(ctx).await?;
    crate::transport::engine::contracts::register_engine_transport_triggers_for_runtime_context(
        ctx,
    )
    .await?;
    activation.activate();
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::app::lifecycle::shutdown::ShutdownCoordinator;
    use crate::engine::{
        ActorId, AuthorityGrantId, EngineHostHandle, TriggerTypeDefinition, TriggerTypeId,
        WorkerDefinition, WorkerId, WorkerKind,
    };

    #[test]
    fn sync_trigger_registration_failure_drops_domain_lifecycle_activation() {
        let (ctx, shutdown) = context_with_transport_trigger_owner_conflict();

        let error = register_server_domains_for_context(&ctx)
            .expect_err("conflicting transport trigger type must fail setup");

        assert!(
            error.to_string().contains("owned by"),
            "unexpected setup error: {error}"
        );
        assert_eq!(shutdown.registered_phase_callback_count(), 0);
    }

    #[tokio::test]
    async fn async_trigger_registration_failure_drops_domain_lifecycle_activation() {
        let (ctx, shutdown) = context_with_transport_trigger_owner_conflict();

        let error = register_server_domains_for_runtime_context(&ctx)
            .await
            .expect_err("conflicting transport trigger type must fail setup");

        assert!(
            error.to_string().contains("owned by"),
            "unexpected setup error: {error}"
        );
        assert_eq!(shutdown.registered_phase_callback_count(), 0);
    }

    fn context_with_transport_trigger_owner_conflict()
    -> (ServerRuntimeContext, Arc<ShutdownCoordinator>) {
        let mut ctx = crate::shared::server::test_support::make_test_context();
        ctx.engine_host = EngineHostHandle::new_in_memory().expect("fresh engine host");
        let shutdown = Arc::new(ShutdownCoordinator::new());
        ctx.shutdown_coordinator = Some(shutdown.clone());

        let conflict_worker_id = WorkerId::new("transport_trigger_conflict").unwrap();
        ctx.engine_host
            .register_worker_for_setup(
                WorkerDefinition::new(
                    conflict_worker_id.clone(),
                    WorkerKind::InProcess,
                    ActorId::new("system:transport-trigger-conflict").unwrap(),
                    AuthorityGrantId::new("engine-transport").unwrap(),
                )
                .with_namespace_claim("transport_trigger_conflict"),
                false,
            )
            .expect("register conflict worker");
        ctx.engine_host
            .register_trigger_type_for_setup(
                TriggerTypeDefinition::new(
                    TriggerTypeId::new("engine_ws").unwrap(),
                    conflict_worker_id,
                    "intentional owner conflict",
                ),
                false,
            )
            .expect("register conflicting trigger type");

        (ctx, shutdown)
    }
}
