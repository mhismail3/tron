use std::collections::{BTreeMap, BTreeSet};

use chrono::Utc;

use crate::engine::durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, StoredInvocationOutcome, ledger_failure,
};
use crate::engine::invocation::model::InvocationRecord;
use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::InvocationId;
use crate::engine::kernel::types::CatalogRevision;

/// In-memory ledger store used by `LiveCatalog::new`.
#[derive(Default)]
pub struct InMemoryEngineLedgerStore {
    catalog_revision: CatalogRevision,
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
    fn catalog_revision(&self) -> Result<CatalogRevision> {
        Ok(self.catalog_revision)
    }

    fn advance_catalog_revision(
        &mut self,
        expected: CatalogRevision,
        next: CatalogRevision,
    ) -> Result<()> {
        if self.catalog_revision != expected || next != expected.next() {
            return Err(ledger_failure(
                "advance_catalog_revision",
                format!(
                    "expected durable revision {}, found {}; requested next {}",
                    expected.0, self.catalog_revision.0, next.0
                ),
            ));
        }
        self.catalog_revision = next;
        Ok(())
    }

    fn append_invocation(&mut self, record: &InvocationRecord) -> Result<()> {
        self.invocations.push(record.redacted_for_storage());
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<InvocationRecord>> {
        Ok(self.invocations.clone())
    }

    fn list_invocations_by_session(&self, session_id: &str) -> Result<Vec<InvocationRecord>> {
        Ok(self
            .invocations
            .iter()
            .filter(|record| record.session_id.as_deref() == Some(session_id))
            .cloned()
            .collect())
    }

    fn list_idempotency_by_session(&self, session_id: &str) -> Result<Vec<IdempotencyEntry>> {
        let session_invocations = self
            .invocations
            .iter()
            .filter(|record| record.session_id.as_deref() == Some(session_id))
            .map(|record| record.invocation_id.clone())
            .collect::<BTreeSet<_>>();
        Ok(self
            .idempotency
            .values()
            .filter(|entry| {
                (entry.key.scope.kind == "session" && entry.key.scope.value == session_id)
                    || session_invocations.contains(&entry.first_invocation_id)
                    || session_invocations.contains(&entry.latest_invocation_id)
            })
            .cloned()
            .collect())
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
        entry.outcome = Some(outcome.redacted_for_storage());
        entry.updated_at = Utc::now();
        Ok(())
    }
}
