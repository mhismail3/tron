use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::sqlite::repositories::trace::TraceRepo;
use crate::domains::session::event_store::trace::{AgentTraceListOptions, AgentTraceRecord};

use super::EventStore;

impl EventStore {
    /// Persist a newly-started agent trace record before the effect runs.
    pub fn append_trace_record(&self, record: &AgentTraceRecord) -> Result<()> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            TraceRepo::insert(&conn, record)
        })
    }

    /// Replace an existing trace record after success or failure.
    pub fn update_trace_record(&self, record: &AgentTraceRecord) -> Result<()> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            let updated = TraceRepo::update(&conn, record)?;
            if updated {
                Ok(())
            } else {
                Err(EventStoreError::InvalidOperation(format!(
                    "trace record {} does not exist",
                    record.id
                )))
            }
        })
    }

    /// Get a trace record by id.
    pub fn get_trace_record(&self, id: &str) -> Result<Option<AgentTraceRecord>> {
        let conn = self.conn()?;
        TraceRepo::get(&conn, id)
    }

    /// List trace records.
    pub fn list_trace_records(
        &self,
        options: &AgentTraceListOptions<'_>,
    ) -> Result<Vec<AgentTraceRecord>> {
        let conn = self.conn()?;
        TraceRepo::list(&conn, options)
    }
}
