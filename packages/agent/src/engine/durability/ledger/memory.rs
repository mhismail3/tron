use std::collections::BTreeMap;

use chrono::Utc;

use crate::engine::durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, StoredInvocationOutcome, ledger_failure,
};
use crate::engine::invocation::model::InvocationRecord;
use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::{FunctionId, InvocationId, WorkerId};
use crate::engine::kernel::types::{
    CatalogChange, CatalogRevision, FunctionDefinition, WorkerDefinition,
};

/// In-memory ledger store used by `LiveCatalog::new`.
#[derive(Default)]
pub struct InMemoryEngineLedgerStore {
    catalog_changes: Vec<CatalogChange>,
    invocations: Vec<InvocationRecord>,
    idempotency: BTreeMap<IdempotencyKey, IdempotencyEntry>,
    durable_workers: BTreeMap<WorkerId, WorkerDefinition>,
    durable_functions: BTreeMap<FunctionId, FunctionDefinition>,
}

impl InMemoryEngineLedgerStore {
    /// Create an empty in-memory store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

impl EngineLedgerStore for InMemoryEngineLedgerStore {
    fn append_catalog_change(&mut self, change: &CatalogChange) -> Result<()> {
        self.catalog_changes.push(change.clone());
        Ok(())
    }

    fn list_catalog_changes(&self) -> Result<Vec<CatalogChange>> {
        Ok(self.catalog_changes.clone())
    }

    fn catalog_changes_after(
        &self,
        revision: CatalogRevision,
        limit: usize,
    ) -> Result<Vec<CatalogChange>> {
        Ok(self
            .catalog_changes
            .iter()
            .filter(|change| change.after > revision)
            .take(limit)
            .cloned()
            .collect())
    }

    fn upsert_durable_worker_definition(&mut self, definition: &WorkerDefinition) -> Result<()> {
        self.durable_workers
            .insert(definition.id.clone(), definition.clone());
        Ok(())
    }

    fn remove_durable_worker_definition(&mut self, worker_id: &WorkerId) -> Result<()> {
        self.durable_workers.remove(worker_id);
        self.durable_functions
            .retain(|_, function| &function.owner_worker != worker_id);
        Ok(())
    }

    fn list_durable_worker_definitions(&self) -> Result<Vec<WorkerDefinition>> {
        Ok(self.durable_workers.values().cloned().collect())
    }

    fn upsert_durable_function_definition(
        &mut self,
        definition: &FunctionDefinition,
    ) -> Result<()> {
        self.durable_functions
            .insert(definition.id.clone(), definition.clone());
        Ok(())
    }

    fn remove_durable_function_definition(&mut self, function_id: &FunctionId) -> Result<()> {
        self.durable_functions.remove(function_id);
        Ok(())
    }

    fn list_durable_function_definitions(&self) -> Result<Vec<FunctionDefinition>> {
        Ok(self.durable_functions.values().cloned().collect())
    }

    fn append_invocation(&mut self, record: &InvocationRecord) -> Result<()> {
        self.invocations.push(record.clone());
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<InvocationRecord>> {
        Ok(self.invocations.clone())
    }

    fn reserve_idempotency(
        &mut self,
        reservation: IdempotencyReservation,
    ) -> Result<IdempotencyReservationOutcome> {
        if let Some(existing) = self.idempotency.get_mut(&reservation.key) {
            existing.latest_invocation_id = reservation.invocation_id;
            existing.updated_at = Utc::now();
            return Ok(IdempotencyReservationOutcome::Existing(existing.clone()));
        }

        let now = Utc::now();
        let entry = IdempotencyEntry {
            key: reservation.key,
            payload_fingerprint: reservation.payload_fingerprint,
            function_revision: reservation.function_revision,
            replay_behavior: reservation.replay_behavior,
            status: IdempotencyStatus::InProgress,
            first_invocation_id: reservation.invocation_id.clone(),
            latest_invocation_id: reservation.invocation_id,
            outcome: None,
            created_at: now,
            updated_at: now,
        };
        let _ = self.idempotency.insert(entry.key.clone(), entry.clone());
        Ok(IdempotencyReservationOutcome::Reserved(entry))
    }

    fn complete_idempotency(
        &mut self,
        key: &IdempotencyKey,
        invocation_id: &InvocationId,
        outcome: StoredInvocationOutcome,
    ) -> Result<()> {
        let entry = self
            .idempotency
            .get_mut(key)
            .ok_or_else(|| ledger_failure("complete_idempotency", "reservation not found"))?;
        entry.status = IdempotencyStatus::Completed;
        entry.latest_invocation_id = invocation_id.clone();
        entry.outcome = Some(outcome);
        entry.updated_at = Utc::now();
        Ok(())
    }
}
