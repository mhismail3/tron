//! Sync invocation preparation, completion, and idempotency.

use std::sync::Arc;

use serde_json::Value;

use super::LiveCatalog;
use crate::engine::durability::ledger::{
    IdempotencyReservation, IdempotencyReservationOutcome, StoredInvocationOutcome,
};
use crate::engine::invocation::model::{
    InProcessFunctionHandler, Invocation, InvocationRecord, InvocationResult,
    RUNTIME_METADATA_EXPECTED_FUNCTION_REVISION, RUNTIME_METADATA_EXPECTED_WORKER_VERSION,
};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::WorkerId;
use crate::engine::kernel::types::{FunctionDefinition, FunctionRevision, IdempotencyScope};
use crate::engine::kernel::{policy, schema};

/// A sync invocation that passed routing, policy, schema, and idempotency
/// reservation checks and is ready to execute outside the catalog lock.
pub(in crate::engine) struct PreparedSyncInvocation {
    /// Invocation with its causal catalog revision captured at prepare time.
    pub invocation: Invocation,
    /// Function contract captured at prepare time.
    pub function: FunctionDefinition,
    /// In-process handler captured at prepare time.
    pub handler: Arc<dyn InProcessFunctionHandler>,
    /// Fresh idempotency reservation, when the function is mutating.
    pub idempotency: Option<IdempotencyReservation>,
}

/// Prepare result for a sync invocation.
pub(in crate::engine) enum PreparedSyncInvocationDecision {
    /// The handler should be executed outside the catalog lock.
    Execute(Box<PreparedSyncInvocation>),
    /// The invocation already finished during prepare, usually due to policy,
    /// schema, routing, or idempotency replay/conflict behavior.
    Finished(Box<InvocationResult>),
}

impl LiveCatalog {
    /// Invoke an in-process function synchronously.
    pub async fn invoke_sync(&mut self, invocation: Invocation) -> InvocationResult {
        match self.prepare_sync_invocation(invocation) {
            PreparedSyncInvocationDecision::Finished(result) => *result,
            PreparedSyncInvocationDecision::Execute(prepared) => {
                let result = prepared.handler.invoke(prepared.invocation.clone()).await;
                self.finish_prepared_sync_invocation(*prepared, result)
            }
        }
    }

    /// Prepare an in-process sync invocation without executing the handler.
    pub(in crate::engine) fn prepare_sync_invocation(
        &mut self,
        invocation: Invocation,
    ) -> PreparedSyncInvocationDecision {
        self.prepare_invocation(invocation)
    }

    fn prepare_invocation(&mut self, mut invocation: Invocation) -> PreparedSyncInvocationDecision {
        let Some(entry) = self.functions.get(&invocation.function_id) else {
            let worker_id = WorkerId::new("missing").expect("valid static id");
            let result = InvocationResult::error(
                &invocation,
                worker_id,
                FunctionRevision(0),
                self.revision,
                EngineError::NotFound {
                    kind: "function",
                    id: invocation.function_id.to_string(),
                },
            );
            return PreparedSyncInvocationDecision::Finished(Box::new(self.finish_invocation(
                &invocation,
                result,
                None,
            )));
        };
        let function = entry.definition.clone();
        let handler = entry.handler.clone();

        invocation.causal_context.catalog_revision = self.revision;

        if let Err(err) = validate_advertised_surface(&function, &invocation)
            .and_then(|_| policy::validate_invocation(&function, &invocation))
        {
            let result = InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                err,
            );
            return PreparedSyncInvocationDecision::Finished(Box::new(self.finish_invocation(
                &invocation,
                result,
                None,
            )));
        }

        let idempotency =
            match self.idempotency_lookup(&function, &invocation) {
                Ok(idempotency) => idempotency,
                Err(err) => {
                    let result = InvocationResult::error(
                        &invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        err,
                    );
                    return PreparedSyncInvocationDecision::Finished(Box::new(
                        self.finish_invocation(&invocation, result, None),
                    ));
                }
            };

        if let Some(reservation) = &idempotency {
            match self.ledger.reserve_idempotency(reservation.clone()) {
                Ok(IdempotencyReservationOutcome::Reserved(_)) => {}
                Ok(IdempotencyReservationOutcome::Existing(existing)) => {
                    let result = self.result_for_existing_idempotency(
                        &function,
                        &invocation,
                        &existing,
                        &reservation.payload_fingerprint,
                    );
                    return PreparedSyncInvocationDecision::Finished(Box::new(
                        self.finish_invocation(
                            &invocation,
                            result,
                            Some(existing.key.scope.clone()),
                        ),
                    ));
                }
                Err(err) => {
                    let result = InvocationResult::error(
                        &invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        err,
                    );
                    return PreparedSyncInvocationDecision::Finished(Box::new(
                        self.finish_invocation(
                            &invocation,
                            result,
                            Some(reservation.key.scope.clone()),
                        ),
                    ));
                }
            }
        }

        if let Some(schema) = &function.request_schema {
            if let Err(err) =
                schema::validate_payload(&function.id, "request", schema, &invocation.payload)
            {
                let mut result = InvocationResult::error(
                    &invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    err,
                );
                if let Some(reservation) = &idempotency
                    && let Some(completion_error) = self.complete_invocation_idempotency(
                        reservation,
                        &invocation,
                        &function,
                        &result,
                    )
                {
                    result = completion_error;
                }
                let idempotency_scope = idempotency.map(|reservation| reservation.key.scope);
                return PreparedSyncInvocationDecision::Finished(Box::new(self.finish_invocation(
                    &invocation,
                    result,
                    idempotency_scope,
                )));
            }
        }

        let Some(handler) = handler else {
            let mut result = InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::NotRoutable {
                    function_id: invocation.function_id.to_string(),
                    reason: "no in-process handler".to_owned(),
                },
            );
            if let Some(reservation) = &idempotency
                && let Some(completion_error) = self.complete_invocation_idempotency(
                    reservation,
                    &invocation,
                    &function,
                    &result,
                )
            {
                result = completion_error;
            }
            let idempotency_scope = idempotency.map(|reservation| reservation.key.scope);
            return PreparedSyncInvocationDecision::Finished(Box::new(self.finish_invocation(
                &invocation,
                result,
                idempotency_scope,
            )));
        };

        PreparedSyncInvocationDecision::Execute(Box::new(PreparedSyncInvocation {
            invocation,
            function,
            handler,
            idempotency,
        }))
    }

    /// Finish an invocation whose handler already executed outside the catalog
    /// lock.
    pub(in crate::engine) fn finish_prepared_sync_invocation(
        &mut self,
        prepared: PreparedSyncInvocation,
        handler_result: Result<Value>,
    ) -> InvocationResult {
        let PreparedSyncInvocation {
            invocation,
            function,
            idempotency,
            ..
        } = prepared;
        let captured_revision = invocation.causal_context.catalog_revision;

        let result = match handler_result {
            Ok(value) => {
                if let Some(schema) = &function.response_schema {
                    if let Err(err) =
                        schema::validate_payload(&function.id, "response", schema, &value)
                    {
                        InvocationResult::error(
                            &invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            captured_revision,
                            err,
                        )
                    } else {
                        InvocationResult::success(
                            &invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            captured_revision,
                            value,
                        )
                    }
                } else {
                    InvocationResult::success(
                        &invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        captured_revision,
                        value,
                    )
                }
            }
            Err(err) => InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                captured_revision,
                err,
            ),
        };

        if let Some(reservation) = &idempotency {
            if let Err(err) = self.ledger.complete_idempotency(
                &reservation.key,
                &invocation.id,
                StoredInvocationOutcome::from_result(&result),
            ) {
                let result = InvocationResult::error(
                    &invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    captured_revision,
                    err,
                );
                return self.finish_invocation(
                    &invocation,
                    result,
                    Some(reservation.key.scope.clone()),
                );
            }
        }
        let idempotency_scope = idempotency.map(|reservation| reservation.key.scope);
        self.finish_invocation(&invocation, result, idempotency_scope)
    }

    fn finish_invocation(
        &mut self,
        invocation: &Invocation,
        result: InvocationResult,
        idempotency_scope: Option<IdempotencyScope>,
    ) -> InvocationResult {
        self.record_invocation_result(invocation, result, idempotency_scope)
    }

    /// Record an invocation result produced by a privileged host path.
    pub fn record_invocation_result(
        &mut self,
        invocation: &Invocation,
        result: InvocationResult,
        idempotency_scope: Option<IdempotencyScope>,
    ) -> InvocationResult {
        let record = InvocationRecord::from_result(invocation, &result, idempotency_scope);
        if let Err(err) = self.ledger.append_invocation(&record) {
            return InvocationResult::error(
                invocation,
                result.worker_id,
                result.function_revision,
                self.revision,
                err,
            );
        }
        result
    }
}

fn validate_advertised_surface(
    function: &FunctionDefinition,
    invocation: &Invocation,
) -> Result<()> {
    let Some(expected_revision) = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_EXPECTED_FUNCTION_REVISION)
    else {
        return Ok(());
    };
    let expected_revision = expected_revision.parse::<u64>().map_err(|_| {
        EngineError::PolicyViolation(format!(
            "invalid runtime function revision pin for {}",
            function.id
        ))
    })?;
    let expected_worker_version = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_EXPECTED_WORKER_VERSION)
        .map(ToOwned::to_owned);
    let actual_worker_version = function
        .metadata
        .get("workerVersion")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    if expected_revision == function.revision.0 && expected_worker_version == actual_worker_version
    {
        return Ok(());
    }
    Err(EngineError::StaleFunctionSurface {
        function_id: function.id.to_string(),
        expected_revision,
        actual_revision: function.revision.0,
        expected_worker_version,
        actual_worker_version,
    })
}
