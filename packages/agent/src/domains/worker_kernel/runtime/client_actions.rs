//! Native-client action ownership.
//!
//! A client action is immutable bundle metadata activated through ordinary
//! worker publication. This module exposes only the current healthy owner to
//! authenticated clients; capture and presentation stay client-owned, while
//! execution still uses the normal durable worker dispatcher.

use super::*;

impl WorkerRuntime {
    /// Native client actions are latency-sensitive interactive capabilities.
    /// When their owner is a resident service, activation owns readiness so a
    /// client never pays model/process cold-start cost after completing input.
    /// Ordinary service workers remain lazy.
    pub(super) async fn ensure_native_client_service(
        &self,
        worker: &ActiveWorker,
    ) -> Result<(), String> {
        if worker.bundle.client_actions.is_empty() {
            return Ok(());
        }
        let WorkerRunner::Service {
            command,
            health_url,
            ..
        } = &worker.bundle.runner
        else {
            return Ok(());
        };
        let secrets = self.load_secrets(&worker.bundle)?;
        self.ensure_resident(worker, command, health_url.as_deref(), &secrets)
            .await
    }

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

    pub(super) fn client_delivery_inventory(&self) -> Result<Vec<Value>, String> {
        let mut inventory = Vec::new();
        for summary in self.store.list(true)? {
            if !summary.enabled || summary.retired || summary.health != "healthy" {
                continue;
            }
            let worker = self.store.load_indexed_active(&summary.worker_id)?;
            for delivery in &worker.bundle.client_deliveries {
                inventory.push(json!({
                    "delivery":delivery.as_str(),
                    "workerId":worker.summary.worker_id,
                    "workerVersion":worker.summary.active_version,
                }));
            }
        }
        inventory.sort_by(|left, right| {
            left["delivery"]
                .as_str()
                .cmp(&right["delivery"].as_str())
                .then_with(|| left["workerId"].as_str().cmp(&right["workerId"].as_str()))
        });
        Ok(inventory)
    }
}
