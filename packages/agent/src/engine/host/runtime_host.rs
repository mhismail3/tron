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
