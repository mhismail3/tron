//! Job workflow operations.
use super::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, FunctionDefinition,
    FunctionId, IdempotencyContract, Provenance, RiskLevel,
};
use crate::domains::catalog;
use crate::domains::job::Deps;
use crate::domains::job::contract;
use crate::domains::job::handlers;
use crate::domains::worker::DomainFunctionRegistration;
use crate::domains::worker::DomainRegistrationContext;
use crate::engine::VisibilityScope;
use serde_json::json;

pub(crate) fn hidden_function_registrations(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    let domain_deps = Deps::from_engine(deps);
    [
        (
            "job::background_apply",
            "job::background",
            "apply a queued background-job command",
        ),
        (
            "job::cancel_apply",
            "job::cancel",
            "apply a queued job-cancel command",
        ),
    ]
    .into_iter()
    .map(|(id, public_method, description)| {
        let mut definition = FunctionDefinition::new(
            FunctionId::new(id)?,
            catalog::worker_id("job")?,
            description,
            VisibilityScope::Internal,
            EffectClass::ReversibleSideEffect,
        )
        .with_risk(RiskLevel::High)
        .with_required_authority(AuthorityRequirement::scope("job.write"))
        .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
        .with_compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "hidden job apply functions delegate to the process manager; queue/idempotency records prevent duplicate starts or cancellations",
        ))
        .with_provenance(Provenance::system());
        if let Some(public_contract) = contract::capabilities()?
            .into_iter()
            .find(|spec| spec.function_id.as_str() == public_method)
        {
            if let Some(schema) = public_contract.request_schema {
                definition = definition.with_request_schema(schema);
            }
            if let Some(schema) = public_contract.response_schema {
                definition = definition.with_response_schema(schema);
            }
        }
        definition.metadata = json!({
            "internal": true,
            "canonicalCapability": id,
            "hiddenApplyFunction": true,
        });
        Ok(DomainFunctionRegistration {
            definition,
            handler: handlers::handler_for_operation(
                id.rsplit_once("::").map(|(_, key)| key).unwrap_or(id),
                domain_deps.clone(),
            )?,
        })
    })
    .collect()
}
