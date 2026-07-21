//! Row decoders for the SQLite engine ledger store.

use super::super::IdempotencyEntry;
use super::super::sqlite_codec::{
    RawIdempotencyRow, RawInvocationRow, raw_idempotency_entry, raw_invocation_record,
    resolve_optional_stored_json_string, sqlite_err,
};
use super::SqliteEngineLedgerStore;
use crate::engine::invocation::model::InvocationRecord;
use crate::engine::kernel::errors::Result;

impl SqliteEngineLedgerStore {
    pub(super) fn invocation_record_from_row(
        &self,
        row: &rusqlite::Row<'_>,
    ) -> Result<InvocationRecord> {
        raw_invocation_record(RawInvocationRow {
            invocation_id: row.get(0).map_err(|err| sqlite_err("inv.id", err))?,
            function_id: row.get(1).map_err(|err| sqlite_err("inv.function", err))?,
            worker_id: row.get(2).map_err(|err| sqlite_err("inv.worker", err))?,
            function_revision: row
                .get(3)
                .map_err(|err| sqlite_err("inv.function_revision", err))?,
            catalog_revision: row
                .get(4)
                .map_err(|err| sqlite_err("inv.catalog_revision", err))?,
            actor_id: row.get(5).map_err(|err| sqlite_err("inv.actor", err))?,
            actor_kind_json: row
                .get(6)
                .map_err(|err| sqlite_err("inv.actor_kind", err))?,
            trace_id: row.get(7).map_err(|err| sqlite_err("inv.trace", err))?,
            parent_invocation_id: row.get(8).map_err(|err| sqlite_err("inv.parent", err))?,
            session_id: row.get(9).map_err(|err| sqlite_err("inv.session", err))?,
            workspace_id: row
                .get(10)
                .map_err(|err| sqlite_err("inv.workspace", err))?,
            idempotency_scope_kind: row
                .get(11)
                .map_err(|err| sqlite_err("inv.scope_kind", err))?,
            idempotency_scope_value: row
                .get(12)
                .map_err(|err| sqlite_err("inv.scope_value", err))?,
            idempotency_key: row
                .get(13)
                .map_err(|err| sqlite_err("inv.idempotency_key", err))?,
            replayed_from: row
                .get(14)
                .map_err(|err| sqlite_err("inv.replayed_from", err))?,
            succeeded: row
                .get(15)
                .map_err(|err| sqlite_err("inv.succeeded", err))?,
            result_json: resolve_optional_stored_json_string(
                &self.conn,
                row.get(16).map_err(|err| sqlite_err("inv.result", err))?,
            )?,
            error_json: resolve_optional_stored_json_string(
                &self.conn,
                row.get(17).map_err(|err| sqlite_err("inv.error", err))?,
            )?,
            timestamp: row
                .get(18)
                .map_err(|err| sqlite_err("inv.timestamp", err))?,
        })
    }

    pub(super) fn idempotency_entry_from_row(
        &self,
        row: &rusqlite::Row<'_>,
    ) -> Result<IdempotencyEntry> {
        raw_idempotency_entry(RawIdempotencyRow {
            function_id: row
                .get(0)
                .map_err(|err| sqlite_err("idempotency.function_id", err))?,
            scope_kind: row
                .get(1)
                .map_err(|err| sqlite_err("idempotency.scope_kind", err))?,
            scope_value: row
                .get(2)
                .map_err(|err| sqlite_err("idempotency.scope_value", err))?,
            idempotency_key: row
                .get(3)
                .map_err(|err| sqlite_err("idempotency.key", err))?,
            payload_fingerprint: row
                .get(4)
                .map_err(|err| sqlite_err("idempotency.payload_fingerprint", err))?,
            function_revision: row
                .get(5)
                .map_err(|err| sqlite_err("idempotency.function_revision", err))?,
            status_json: row
                .get(6)
                .map_err(|err| sqlite_err("idempotency.status", err))?,
            first_invocation_id: row
                .get(7)
                .map_err(|err| sqlite_err("idempotency.first_invocation_id", err))?,
            latest_invocation_id: row
                .get(8)
                .map_err(|err| sqlite_err("idempotency.latest_invocation_id", err))?,
            outcome_value_json: resolve_optional_stored_json_string(
                &self.conn,
                row.get(9)
                    .map_err(|err| sqlite_err("idempotency.outcome_value", err))?,
            )?,
            outcome_error_json: resolve_optional_stored_json_string(
                &self.conn,
                row.get(10)
                    .map_err(|err| sqlite_err("idempotency.outcome_error", err))?,
            )?,
            created_at: row
                .get(11)
                .map_err(|err| sqlite_err("idempotency.created_at", err))?,
            updated_at: row
                .get(12)
                .map_err(|err| sqlite_err("idempotency.updated_at", err))?,
        })
    }
}
