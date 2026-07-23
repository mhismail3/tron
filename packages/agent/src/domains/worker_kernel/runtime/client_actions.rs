//! Native-client action ownership.
//!
//! A client action is immutable bundle metadata activated through ordinary
//! worker publication. This module exposes only the current healthy owner to
//! authenticated clients; capture and presentation stay client-owned, while
//! execution still uses the normal durable worker dispatcher.

use super::*;

impl WorkerRuntime {
    pub(super) fn client_action_inventory(&self) -> Result<Vec<Value>, String> {
        WorkerClientAction::all()
            .iter()
            .filter_map(|action| match self.active_client_action(*action) {
                Ok(Some(worker)) => Some(Ok(json!({
                    "action": action.as_str(),
                    "workerId": worker.summary.worker_id,
                    "workerVersion": worker.summary.active_version,
                }))),
                Ok(None) => None,
                Err(error) => Some(Err(error)),
            })
            .collect()
    }

    fn active_client_action(
        &self,
        action: WorkerClientAction,
    ) -> Result<Option<ActiveWorker>, String> {
        for summary in self.store.list(true)? {
            let worker = self.store.load_indexed_active(&summary.worker_id)?;
            if worker.bundle.client_actions.contains(&action) {
                return Ok(
                    (summary.enabled && !summary.retired && summary.health == "healthy")
                        .then_some(worker),
                );
            }
        }
        Ok(None)
    }
}
