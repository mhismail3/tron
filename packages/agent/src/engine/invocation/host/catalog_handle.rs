//! Catalog registration, discovery, watch, and promotion methods on `EngineHostHandle`.

use super::*;

impl EngineHostHandle {
    /// Register or update a worker through the host boundary.
    pub async fn register_worker(
        &self,
        definition: WorkerDefinition,
        volatile: bool,
    ) -> Result<WorkerRevision> {
        self.inner
            .lock()
            .await
            .catalog
            .register_worker(definition, volatile)
    }

    /// Unregister a worker and clean up its volatile owned entries.
    pub async fn unregister_worker(&self, id: &WorkerId, owner_actor: &str) -> Result<()> {
        self.inner
            .lock()
            .await
            .catalog
            .unregister_worker(id, owner_actor)
    }

    /// Register or update a worker during single-threaded startup/test setup.
    ///
    /// This fails closed if the host is already in use, keeping setup code from
    /// blocking on a global engine mutex.
    pub fn register_worker_for_setup(
        &self,
        definition: WorkerDefinition,
        volatile: bool,
    ) -> Result<WorkerRevision> {
        self.inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation("engine host is busy during worker setup".to_owned())
            })?
            .catalog
            .register_worker(definition, volatile)
    }

    /// Register or update a function through the host boundary.
    pub async fn register_function(
        &self,
        definition: FunctionDefinition,
        handler: Option<Arc<dyn InProcessFunctionHandler>>,
        volatile: bool,
    ) -> Result<FunctionRevision> {
        self.inner
            .lock()
            .await
            .catalog
            .register_function(definition, handler, volatile)
    }

    /// Register or update a function during single-threaded startup/test setup.
    ///
    /// This is the synchronous counterpart to [`Self::register_function`] for
    /// builders that assemble a full server context before any async work has
    /// started.
    pub fn register_function_for_setup(
        &self,
        definition: FunctionDefinition,
        handler: Option<Arc<dyn InProcessFunctionHandler>>,
        volatile: bool,
    ) -> Result<FunctionRevision> {
        self.inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation("engine host is busy during function setup".to_owned())
            })?
            .catalog
            .register_function(definition, handler, volatile)
    }

    /// Return the SQLite storage path when this host is backed by the durable
    /// engine ledger. In-memory hosts return `None`.
    pub async fn storage_path(&self) -> Option<PathBuf> {
        self.inner.lock().await.storage_path.clone()
    }

    /// Return the SQLite storage path during startup/test setup without waiting
    /// on an already-running host.
    pub fn storage_path_for_setup(&self) -> Result<Option<PathBuf>> {
        Ok(self
            .inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation(
                    "engine host is busy during storage path setup".to_owned(),
                )
            })?
            .storage_path
            .clone())
    }

    /// Unregister a function through the host boundary.
    pub async fn unregister_function(&self, id: &FunctionId, owner: &WorkerId) -> Result<()> {
        self.inner
            .lock()
            .await
            .catalog
            .unregister_function(id, owner)
    }

    /// Register or update a trigger type through the host boundary.
    pub async fn register_trigger_type(
        &self,
        definition: TriggerTypeDefinition,
        volatile: bool,
    ) -> Result<()> {
        self.inner
            .lock()
            .await
            .catalog
            .register_trigger_type(definition, volatile)
    }

    /// Register or update a trigger type during single-threaded setup.
    pub fn register_trigger_type_for_setup(
        &self,
        definition: TriggerTypeDefinition,
        volatile: bool,
    ) -> Result<()> {
        self.inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation(
                    "engine host is busy during trigger-type setup".to_owned(),
                )
            })?
            .catalog
            .register_trigger_type(definition, volatile)
    }

    /// Register or update a trigger through the host boundary.
    pub async fn register_trigger(
        &self,
        definition: TriggerDefinition,
        volatile: bool,
    ) -> Result<TriggerRevision> {
        self.inner
            .lock()
            .await
            .catalog
            .register_trigger(definition, volatile)
    }

    /// Register or update a trigger during single-threaded setup.
    pub fn register_trigger_for_setup(
        &self,
        definition: TriggerDefinition,
        volatile: bool,
    ) -> Result<TriggerRevision> {
        self.inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation("engine host is busy during trigger setup".to_owned())
            })?
            .catalog
            .register_trigger(definition, volatile)
    }

    /// Unregister a trigger through the host boundary.
    pub async fn unregister_trigger(
        &self,
        id: &TriggerId,
        owner_worker: &WorkerId,
    ) -> Result<bool> {
        self.inner
            .lock()
            .await
            .catalog
            .unregister_trigger(id, owner_worker)
    }

    /// Discover visible functions through the host boundary.
    pub async fn discover(&self, query: &FunctionQuery) -> Vec<FunctionDefinition> {
        self.inner.lock().await.catalog.discover_functions(query)
    }

    /// Inspect a visible function through the host boundary.
    pub async fn inspect_function(
        &self,
        id: &FunctionId,
        actor: Option<&ActorContext>,
    ) -> Result<FunctionDefinition> {
        self.inner.lock().await.catalog.inspect_function(id, actor)
    }

    /// Inspect a worker through the host boundary.
    pub async fn inspect_worker(&self, id: &WorkerId) -> Result<WorkerDefinition> {
        self.inner.lock().await.catalog.inspect_worker(id)
    }

    /// List workers visible to an actor through the host boundary.
    pub async fn visible_workers(&self, actor: &ActorContext) -> Vec<WorkerDefinition> {
        self.inner.lock().await.visible_workers(actor)
    }

    /// Return whether a worker is a volatile runtime registration.
    pub async fn worker_is_volatile(&self, id: &WorkerId) -> Option<bool> {
        self.inner.lock().await.catalog.worker_is_volatile(id)
    }

    /// Return a snapshot of invocation records.
    pub async fn invocation_records(
        &self,
    ) -> Vec<crate::engine::invocation::model::InvocationRecord> {
        self.inner.lock().await.catalog.invocations().to_vec()
    }

    /// Inspect a trigger through the host boundary.
    pub async fn inspect_trigger(&self, id: &TriggerId) -> Result<TriggerDefinition> {
        self.inner.lock().await.catalog.inspect_trigger(id)
    }

    /// List triggers visible to an actor through the host boundary.
    pub async fn visible_triggers(&self, actor: &ActorContext) -> Vec<TriggerDefinition> {
        self.inner.lock().await.visible_triggers(actor)
    }

    /// Inspect a trigger type through the host boundary.
    pub async fn inspect_trigger_type(&self, id: &TriggerTypeId) -> Result<TriggerTypeDefinition> {
        self.inner.lock().await.catalog.inspect_trigger_type(id)
    }

    /// List trigger types visible to an actor through the host boundary.
    pub async fn visible_trigger_types(&self, actor: &ActorContext) -> Vec<TriggerTypeDefinition> {
        self.inner.lock().await.visible_trigger_types(actor)
    }

    /// Watch catalog changes through the host boundary.
    pub async fn watch(
        &self,
        actor: &ActorContext,
        request: CatalogWatchRequest,
    ) -> Result<CatalogWatchResponse> {
        self.inner.lock().await.watch_catalog(actor, request)
    }

    /// Return the current live catalog revision.
    pub async fn catalog_revision(&self) -> CatalogRevision {
        self.inner.lock().await.catalog.revision()
    }

    /// Promote function visibility through the host boundary.
    pub async fn promote_function_visibility(
        &self,
        id: &FunctionId,
        owner: &WorkerId,
        target: VisibilityScope,
        workspace_id: Option<String>,
    ) -> Result<FunctionRevision> {
        self.inner
            .lock()
            .await
            .catalog
            .promote_function_visibility(id, owner, target, workspace_id)
    }
}
