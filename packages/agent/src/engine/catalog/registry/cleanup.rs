//! Catalog cleanup helpers for owned functions and triggers.

use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::{FunctionId, TriggerId, TriggerTypeId, WorkerId};
use crate::engine::kernel::types::CatalogChangeKind;

use super::LiveCatalog;
use super::catalog_changes::{
    function_change_subject, trigger_change_subject, trigger_type_change_subject,
};

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

        let trigger_ids: Vec<TriggerId> = self
            .triggers
            .iter()
            .filter(|(_, entry)| entry.volatile && &entry.definition.owner_worker == worker_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in trigger_ids {
            if let Some(entry) = self.triggers.get(&id) {
                let subject = trigger_change_subject(&entry.definition);
                self.record_change(CatalogChangeKind::TriggerUnregistered, subject)?;
                let _ = self.triggers.remove(&id);
            }
        }

        let trigger_type_ids: Vec<TriggerTypeId> = self
            .trigger_types
            .iter()
            .filter(|(_, entry)| entry.volatile && &entry.definition.owner_worker == worker_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in trigger_type_ids {
            if let Some(entry) = self.trigger_types.get(&id) {
                let subject = trigger_type_change_subject(&entry.definition);
                self.record_change(CatalogChangeKind::TriggerTypeUnregistered, subject)?;
                let _ = self.trigger_types.remove(&id);
            }
        }
        Ok(())
    }

    pub(super) fn cleanup_triggers_targeting(&mut self, function_id: &FunctionId) -> Result<()> {
        let trigger_ids: Vec<TriggerId> = self
            .triggers
            .iter()
            .filter(|(_, entry)| &entry.definition.target_function == function_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in trigger_ids {
            if let Some(removed) = self.triggers.get(&id) {
                let subject = trigger_change_subject(&removed.definition);
                self.record_change(CatalogChangeKind::TriggerUnregistered, subject)?;
                let _ = self.triggers.remove(&id);
            }
        }
        Ok(())
    }
}
