//! Catalog cleanup helpers for owned functions.

use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::{FunctionId, WorkerId};
use crate::engine::kernel::types::CatalogChangeKind;

use super::LiveCatalog;
use super::catalog_changes::function_change_subject;

impl LiveCatalog {
    pub(super) fn cleanup_owned_volatile(&mut self, worker_id: &WorkerId) -> Result<()> {
        let function_ids: Vec<FunctionId> = self
            .functions
            .iter()
            .filter(|(_, entry)| entry.volatile && &entry.definition.owner_worker == worker_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in function_ids {
            if let Some(entry) = self.functions.get(&id) {
                let subject = function_change_subject(&entry.definition);
                self.record_change(CatalogChangeKind::FunctionUnregistered, subject)?;
                let _ = self.functions.remove(&id);
            }
        }
        Ok(())
    }
}
