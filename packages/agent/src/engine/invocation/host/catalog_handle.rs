//! Function registration, discovery, and inspection methods on `EngineHostHandle`.

use super::*;

impl EngineHostHandle {
    /// Register or update a function through the host boundary.
    pub async fn register_function(
        &self,
        definition: FunctionDefinition,
        handler: Arc<dyn InProcessFunctionHandler>,
    ) -> Result<FunctionRevision> {
        self.inner
            .lock()
            .await
            .catalog
            .register_function(definition, handler)
    }

    /// Register or update a function during single-threaded startup/test setup.
    ///
    /// This is the synchronous counterpart to [`Self::register_function`] for
    /// builders that assemble a full server context before any async work has
    /// started.
    pub fn register_function_for_setup(
        &self,
        definition: FunctionDefinition,
        handler: Arc<dyn InProcessFunctionHandler>,
    ) -> Result<FunctionRevision> {
        self.inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation("engine host is busy during function setup".to_owned())
            })?
            .catalog
            .register_function(definition, handler)
    }

    /// Unregister a function through the host boundary.
    pub async fn unregister_function(&self, id: &FunctionId, owner: &WorkerId) -> Result<()> {
        self.inner
            .lock()
            .await
            .catalog
            .unregister_function(id, owner)
    }

    /// Discover visible functions through the host boundary.
    pub async fn visible_functions(&self, actor: &ActorContext) -> Vec<FunctionDefinition> {
        self.inner.lock().await.catalog.visible_functions(actor)
    }

    /// Discover visible functions and capture the matching catalog revision
    /// under one host lock.
    ///
    /// Provider surfaces use this instead of separate discovery/revision calls
    /// so their audit snapshot identifies the exact catalog view from which
    /// tool contracts were selected.
    pub async fn visible_functions_with_revision(
        &self,
        actor: &ActorContext,
    ) -> (CatalogRevision, Vec<FunctionDefinition>) {
        let host = self.inner.lock().await;
        (
            host.catalog.revision(),
            host.catalog.visible_functions(actor),
        )
    }

    /// Inspect a visible function through the host boundary.
    pub async fn inspect_function(
        &self,
        id: &FunctionId,
        actor: &ActorContext,
    ) -> Result<FunctionDefinition> {
        self.inner.lock().await.catalog.inspect_function(id, actor)
    }
}
