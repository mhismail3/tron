use crate::events::errors::Result;
use crate::events::sqlite::repositories::constitution::{
    ConstitutionAuditRepo, ContextResolutionAudit, ProviderPayloadAudit,
};

use super::EventStore;

impl EventStore {
    /// Record a Constitution context-resolution audit.
    ///
    /// This is deliberately outside the session event chain: it is replay
    /// metadata for how model input was assembled, not part of the user-visible
    /// conversation timeline.
    pub fn record_constitution_context_resolution(
        &self,
        input: &ContextResolutionAudit<'_>,
    ) -> Result<String> {
        self.with_global_write_lock(|| {
            let mut conn = self.conn()?;
            let tx = conn.transaction()?;
            let id = ConstitutionAuditRepo::insert_context_resolution(&tx, input)?;
            tx.commit()?;
            Ok(id)
        })
    }

    /// Record a Constitution provider-payload audit.
    pub fn record_constitution_provider_payload(
        &self,
        input: &ProviderPayloadAudit<'_>,
    ) -> Result<String> {
        self.with_global_write_lock(|| {
            let mut conn = self.conn()?;
            let tx = conn.transaction()?;
            let id = ConstitutionAuditRepo::insert_provider_payload(&tx, input)?;
            tx.commit()?;
            Ok(id)
        })
    }
}
