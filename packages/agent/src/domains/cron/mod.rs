//! cron domain worker.
//!
//! This module owns canonical function execution for the cron namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Scheduler projection and hidden scheduled-fire registration stay at setup
//! time here; automation reads/writes, explicit runs, scheduled-fire apply, and
//! cron run stream publication live in `operations/` and the typed `stream.rs`
//! publisher.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod implementation;
pub(crate) mod operations;
pub(crate) mod stream;
pub(crate) use deps::Deps;
pub use implementation::*;

use serde_json::json;

use crate::domains::catalog;
use crate::domains::worker::DomainFunctionRegistration;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::VisibilityScope;
use crate::shared::server::errors::CapabilityError;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let mut module = {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "cron",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }?;
    module
        .functions
        .extend(hidden_function_registrations(deps)?);
    Ok(module)
}

use crate::engine::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, FunctionDefinition,
    FunctionId, IdempotencyContract, Provenance, Result as EngineResult, RiskLevel,
};

pub mod callbacks;

fn scheduler(
    deps: &Deps,
) -> Result<&std::sync::Arc<crate::domains::cron::CronScheduler>, CapabilityError> {
    deps.cron_scheduler
        .as_ref()
        .ok_or(CapabilityError::NotAvailable {
            message: "Cron scheduler not available".into(),
        })
}

pub(crate) fn project_all_cron_triggers_for_setup(
    handle: &crate::engine::EngineHostHandle,
    deps: &Deps,
) -> EngineResult<()> {
    let Some(scheduler) = deps.cron_scheduler.as_ref() else {
        return Ok(());
    };
    for job in scheduler.jobs().values() {
        handle.register_trigger_for_setup(
            crate::domains::cron::CronScheduler::schedule_trigger_definition(job)?,
            false,
        )?;
    }
    Ok(())
}

async fn project_cron_trigger(
    handle: &crate::engine::EngineHostHandle,
    job: &crate::domains::cron::CronJob,
) -> EngineResult<()> {
    let _ = handle
        .register_trigger(
            crate::domains::cron::CronScheduler::schedule_trigger_definition(job)?,
            false,
        )
        .await?;
    Ok(())
}

pub(crate) fn hidden_function_registrations(
    deps: &DomainRegistrationContext,
) -> EngineResult<Vec<DomainFunctionRegistration>> {
    let domain_deps = Deps::from_engine(deps);
    let mut definition = FunctionDefinition::new(
        FunctionId::new("cron::scheduled_fire")?,
        catalog::worker_id("cron")?,
        "apply one cron schedule fire through the engine trigger runtime",
        VisibilityScope::Internal,
        EffectClass::ExternalSideEffect,
    )
    .with_risk(RiskLevel::High)
    .with_required_authority(AuthorityRequirement::scope("cron.write"))
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "cron scheduled fires execute existing cron payload boundaries and are audited through cron run history",
    ))
    .with_provenance(Provenance::system())
    .with_request_schema(json!({
        "type": "object",
        "required": ["jobId", "scheduledAt"],
        "additionalProperties": false,
        "properties": {
            "jobId": {"type": "string"},
            "scheduledAt": {"type": ["string", "integer"]}
        }
    }))
    .with_response_schema(json!({
        "type": "object",
        "required": ["started", "skipped", "jobId", "scheduledAt"],
        "additionalProperties": false,
        "properties": {
            "started": {"type": "boolean"},
            "skipped": {"type": "boolean"},
            "reason": {"type": "string"},
            "jobId": {"type": "string"},
            "scheduledAt": {"type": "string"},
            "nextRunAt": {"type": ["string", "null"]}
        }
    }));
    definition.metadata = json!({
        "internal": true,
        "canonicalCapability": "cron::scheduled_fire",
        "hiddenCronScheduleFunction": true,
    });
    Ok(vec![DomainFunctionRegistration {
        definition,
        handler: handlers::handler_for_operation("scheduled_fire", domain_deps)?,
    }])
}
