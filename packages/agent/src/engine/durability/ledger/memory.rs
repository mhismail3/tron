use std::collections::BTreeMap;

use chrono::Utc;

use crate::engine::durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, StoredInvocationOutcome, ledger_failure,
};
use crate::engine::invocation::model::InvocationRecord;
use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::InvocationId;
use crate::engine::kernel::types::{CatalogChange, CatalogRevision};

/// In-memory ledger store used by `LiveCatalog::new`.
#[derive(Default)]
pub struct InMemoryEngineLedgerStore {
    catalog_changes: Vec<CatalogChange>,
    invocations: Vec<InvocationRecord>,
    idempotency: BTreeMap<IdempotencyKey, IdempotencyEntry>,
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
