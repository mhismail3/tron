//! Host-dispatched primitive runtime implementation.
//!
//! Primitive functions need a narrow view of catalog, resources, streams,
//! queues, grants, and storage. This file owns the
//! `PrimitiveRuntimeHost` implementation so the host root can focus on lock
//! choreography and invocation flow.

use super::*;

impl primitives::runtime::PrimitiveRuntimeHost for EngineHost {
    fn catalog_revision(&self) -> CatalogRevision {
        self.catalog.revision()
    }

    fn discover_functions(&self, query: &FunctionQuery) -> Vec<FunctionDefinition> {
        self.catalog.discover_functions(query)
    }

    fn visible_workers(&self, actor: &ActorContext) -> Vec<WorkerDefinition> {
        EngineHost::visible_workers(self, actor)
    }

    fn visible_triggers(&self, actor: &ActorContext) -> Vec<TriggerDefinition> {
        EngineHost::visible_triggers(self, actor)
    }

    fn visible_trigger_types(&self, actor: &ActorContext) -> Vec<TriggerTypeDefinition> {
        EngineHost::visible_trigger_types(self, actor)
    }

    fn inspect_catalog_item(&self, invocation: &Invocation) -> Result<Value> {
        self.meta_inspect(invocation)
    }

    fn watch_catalog_snapshot_base(&self, invocation: &Invocation) -> Result<Value> {
        self.meta_watch(invocation)
    }

    fn inspect_worker(&self, id: &WorkerId) -> Result<WorkerDefinition> {
        self.catalog.inspect_worker(id)
    }

    fn worker_is_volatile(&self, id: &WorkerId) -> Option<bool> {
        self.catalog.worker_is_volatile(id)
    }

    fn unregister_worker(&mut self, id: &WorkerId, owner_actor: &str) -> Result<()> {
        self.catalog.unregister_worker(id, owner_actor)
    }

    fn invocations(&self) -> Vec<super::super::invocation::InvocationRecord> {
        self.catalog.invocations().to_vec()
    }

    fn ledger_catalog_changes(&self) -> Result<Vec<CatalogChange>> {
        self.catalog.ledger_catalog_changes()
    }

    fn stream_records_for_trace(&self, trace_id: &str) -> Result<Vec<EngineStreamEvent>> {
        self.primitives
            .streams
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .list_by_trace(trace_id, 500)
    }

    fn queue_items_for_trace(&self, trace_id: &str) -> Result<Vec<EngineQueueItem>> {
        self.primitives
            .queue
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .list_by_trace(trace_id, 500)
    }

    fn resource_events_for_trace(
        &self,
        trace_id: &str,
    ) -> Result<Vec<super::super::resources::EngineResourceEvent>> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .events_by_trace(trace_id, 500)
    }

    fn resource_leases_for_trace(&self, trace_id: &str) -> Result<Vec<EngineResourceLease>> {
        self.primitives
            .leases
            .lock()
            .map_err(|_| EngineError::HandlerFailed("lease store lock poisoned".to_owned()))?
            .list_by_trace(trace_id, 500)
    }

    fn resource_lease(&self, lease_id: &str) -> Result<Option<EngineResourceLease>> {
        self.primitives
            .leases
            .lock()
            .map_err(|_| EngineError::HandlerFailed("lease store lock poisoned".to_owned()))?
            .get(lease_id)
    }

    fn compensation_records_for_trace(&self, trace_id: &str) -> Result<Vec<Value>> {
        self.primitives
            .compensation
            .lock()
            .map_err(|_| EngineError::HandlerFailed("compensation store lock poisoned".to_owned()))?
            .list()
            .map(|records| {
                records
                    .into_iter()
                    .filter(|record| record.trace_id.as_str() == trace_id)
                    .map(|record| json!(record))
                    .collect()
            })
    }

    fn resource_type_definitions(
        &self,
    ) -> Result<Vec<super::super::resources::EngineResourceTypeDefinition>> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .list_types()
    }

    fn list_resources(
        &self,
        filter: super::super::resources::ListResources,
    ) -> Result<Vec<super::super::resources::EngineResource>> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .list(filter)
    }

    fn inspect_resource(
        &self,
        resource_id: &str,
    ) -> Result<Option<super::super::resources::EngineResourceInspection>> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .inspect(resource_id)
    }

    fn create_resource(
        &mut self,
        request: super::super::resources::CreateResource,
    ) -> Result<super::super::resources::EngineResource> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .create(request)
    }

    fn update_resource(
        &mut self,
        request: super::super::resources::UpdateResource,
    ) -> Result<super::super::resources::EngineResourceVersion> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .update(request)
    }

    fn list_grants(
        &self,
        filter: super::super::grants::ListGrants,
    ) -> Result<Vec<super::super::grants::EngineGrant>> {
        self.primitives
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .list(filter)
    }

    fn inspect_grant(
        &self,
        grant_id: &AuthorityGrantId,
    ) -> Result<Option<super::super::grants::EngineGrant>> {
        self.primitives
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .inspect(grant_id)
    }

    fn queue_items(&self, queue: &str, limit: usize) -> Result<Vec<EngineQueueItem>> {
        self.primitives
            .queue
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .list(queue, limit)
    }

    fn storage_stats(&self) -> Result<crate::shared::storage::StorageStatsReport> {
        self.storage_runtime()?.stats().map_err(storage_error)
    }

    fn storage_checkpoint(&self) -> Result<crate::shared::storage::StorageCheckpointReport> {
        self.storage_runtime()?.checkpoint().map_err(storage_error)
    }

    fn storage_export_snapshot(
        &self,
        snapshot_path: &str,
    ) -> Result<crate::shared::storage::StorageExportReport> {
        self.storage_runtime()?
            .export_snapshot(snapshot_path)
            .map_err(storage_error)
    }

    fn storage_retention_run(
        &self,
        dry_run: bool,
        verbose_retention_days: u64,
    ) -> Result<crate::shared::storage::StorageRetentionReport> {
        self.storage_runtime()?
            .retention_run(dry_run, verbose_retention_days)
            .map_err(storage_error)
    }
}
