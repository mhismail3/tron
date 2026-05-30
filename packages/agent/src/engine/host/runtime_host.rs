//! Host-dispatched primitive runtime implementation.
//!
//! Primitive functions need a narrow view of catalog, resources, approvals,
//! streams, queues, grants, storage, and observability. This file owns the
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

    fn approval_records_for_trace(&self, trace_id: &str) -> Result<Vec<EngineApprovalRecord>> {
        self.primitives
            .approvals
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?
            .list(None, None, 500)
            .map(|records| {
                records
                    .into_iter()
                    .filter(|record| record.trace_id.as_str() == trace_id)
                    .collect()
            })
    }

    fn stream_records_for_trace(&self, trace_id: &str) -> Result<Vec<EngineStreamEvent>> {
        self.primitives
            .streams
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .list_by_trace(trace_id, 500)
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

    fn approval_records(
        &self,
        status: Option<ApprovalStatus>,
        session_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineApprovalRecord>> {
        self.primitives
            .approvals
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?
            .list(status, session_id, limit)
    }

    fn worker_count(&self) -> usize {
        self.catalog.workers().len()
    }

    fn function_count(&self) -> usize {
        self.catalog
            .discover_functions(&FunctionQuery::default())
            .len()
    }

    fn trigger_count(&self) -> usize {
        self.catalog.triggers().len()
    }

    fn trigger_type_count(&self) -> usize {
        self.catalog.trigger_types().len()
    }

    fn catalog_change_count(&self) -> usize {
        self.catalog.changes().len()
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

    fn stored_log_values(
        &self,
        query: &LogQueryOptions,
        include_full_payloads: bool,
    ) -> Result<Vec<Value>> {
        let Some(path) = &self.storage_path else {
            return Ok(Vec::new());
        };
        let runtime = crate::shared::storage::StorageRuntime::new(path.clone());
        let conn = runtime.open_connection().map_err(storage_error)?;
        let store = LogStore::new(&conn);
        let mut values = Vec::new();
        for entry in store.query(query) {
            let mut value = json!(entry);
            if include_full_payloads
                && let Some(data) = value.get("data").cloned()
                && data
                    .get(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY)
                    .is_some()
            {
                let stored = serde_json::to_string(&data).map_err(|error| {
                    EngineError::HandlerFailed(format!(
                        "storage log payload expansion failed: {error}"
                    ))
                })?;
                if let Ok(expanded) =
                    crate::shared::storage::resolve_stored_json_value(&conn, &stored)
                {
                    value["data"] = expanded;
                }
            }
            values.push(value);
        }
        Ok(values)
    }
}
