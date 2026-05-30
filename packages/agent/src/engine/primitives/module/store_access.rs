//! Engine store access helpers for module primitive operations.

use super::*;

impl ModulePrimitiveHandler {
    pub(super) fn inspect_resource(
        &self,
        resource_id: &str,
    ) -> Result<Option<EngineResourceInspection>> {
        self.stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .inspect(resource_id)
    }

    pub(super) fn list_resources(&self, filter: ListResources) -> Result<Vec<EngineResource>> {
        self.stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .list(filter)
    }

    pub(super) fn create_resource(&self, request: CreateResource) -> Result<EngineResource> {
        self.stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .create(request)
    }

    pub(super) fn update_resource(&self, request: UpdateResource) -> Result<EngineResourceVersion> {
        self.stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .update(request)
    }

    pub(super) fn link_resources(&self, request: LinkResources) -> Result<()> {
        let _ = self
            .stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .link(request)?;
        Ok(())
    }

    pub(super) fn link_required(
        &self,
        source: &str,
        target: &str,
        relation: &str,
        invocation: &Invocation,
    ) -> Result<()> {
        if self.inspect_resource(source)?.is_some_and(|inspection| {
            inspection
                .outgoing_links
                .iter()
                .any(|link| link.target_resource_id == target && link.relation == relation)
        }) {
            return Ok(());
        }
        self.link_resources(LinkResources {
            source_resource_id: source.to_owned(),
            target_resource_id: target.to_owned(),
            relation: relation.to_owned(),
            metadata: json!({"source": "module", "required": true}),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
    }

    pub(super) fn derive_grant(
        &self,
        request: DeriveGrant,
    ) -> Result<crate::engine::grants::EngineGrant> {
        self.stores
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .derive(request)
    }

    pub(super) fn revoke_grant(
        &self,
        grant_id: &AuthorityGrantId,
        trace_id: crate::engine::ids::TraceId,
    ) -> Result<crate::engine::grants::EngineGrant> {
        self.stores
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .revoke(grant_id, trace_id)
    }

    pub(super) fn inspect_grant(
        &self,
        grant_id: &AuthorityGrantId,
    ) -> Result<Option<crate::engine::grants::EngineGrant>> {
        self.stores
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .inspect(grant_id)
    }

    pub(super) fn list_grants(&self, filter: ListGrants) -> Result<Vec<EngineGrant>> {
        self.stores
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .list(filter)
    }

    pub(super) async fn inspect_worker(
        &self,
        worker_id: &WorkerId,
    ) -> Result<crate::engine::WorkerDefinition> {
        self.stores.engine_host()?.inspect_worker(worker_id).await
    }

    pub(super) async fn discover_functions(
        &self,
        query: &FunctionQuery,
    ) -> Vec<FunctionDefinition> {
        match self.stores.engine_host() {
            Ok(host) => host.discover(query).await,
            Err(_) => Vec::new(),
        }
    }

    pub(super) async fn worker_is_volatile(&self, worker_id: &WorkerId) -> Option<bool> {
        self.stores
            .engine_host()
            .ok()?
            .worker_is_volatile(worker_id)
            .await
    }

    pub(super) async fn unregister_worker(
        &self,
        worker_id: &WorkerId,
        owner_actor: &str,
    ) -> Result<()> {
        self.stores
            .engine_host()?
            .unregister_worker(worker_id, owner_actor)
            .await
    }
}
