//! Host construction and built-in capability registration.

use super::*;

impl EngineHost {
    /// Create a host with an in-memory engine ledger.
    pub fn new() -> Result<Self> {
        Self::from_catalog_and_primitives(LiveCatalog::new(), PrimitiveStores::in_memory())
    }

    /// Create a host with a caller-supplied ledger.
    pub fn with_ledger_store(ledger: Box<dyn EngineLedgerStore>) -> Result<Self> {
        Self::from_catalog_and_primitives(
            LiveCatalog::with_ledger_store(ledger),
            PrimitiveStores::in_memory(),
        )
    }

    /// Open a host whose ledger and primitive stores share one SQLite file.
    pub fn open_sqlite(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let storage_runtime = crate::shared::storage::StorageRuntime::new(path.to_path_buf());
        storage_runtime
            .prepare_for_startup()
            .map_err(storage_error)?;
        drop(storage_runtime.open_connection().map_err(storage_error)?);
        let _startup_checkpoint = storage_runtime.checkpoint().map_err(storage_error)?;
        let ledger = SqliteEngineLedgerStore::open(path)?;
        let mut catalog = LiveCatalog::with_ledger_store(Box::new(ledger));
        catalog.hydrate_durable_catalog_from_ledger()?;
        let mut host = Self::from_catalog_and_primitives(catalog, PrimitiveStores::sqlite(path)?)?;
        host.storage_path = Some(path.to_path_buf());
        Ok(host)
    }

    /// Wrap an existing catalog and bootstrap engine transport functions.
    pub fn from_catalog(catalog: LiveCatalog) -> Result<Self> {
        Self::from_catalog_and_primitives(catalog, PrimitiveStores::in_memory())
    }

    fn from_catalog_and_primitives(
        mut catalog: LiveCatalog,
        primitives: PrimitiveStores,
    ) -> Result<Self> {
        catalog.set_grant_store(primitives.grants.clone());
        let mut host = Self {
            catalog,
            primitives,
            storage_path: None,
        };
        host.bootstrap_meta_capabilities()?;
        Ok(host)
    }

    /// Idempotently register the privileged engine worker and meta-functions.
    pub fn bootstrap_meta_capabilities(&mut self) -> Result<()> {
        let engine_worker_id = worker_id(ENGINE_WORKER_ID)?;
        match self.catalog.worker(&engine_worker_id) {
            Some(worker) => {
                if worker.kind != WorkerKind::System
                    || !worker
                        .namespace_claims
                        .iter()
                        .any(|claim| claim == ENGINE_WORKER_ID)
                {
                    return Err(EngineError::PolicyViolation(
                        "reserved engine namespace already has a non-system owner".to_owned(),
                    ));
                }
            }
            None => {
                self.catalog.register_worker(engine_worker(), false)?;
            }
        }

        for definition in meta_function_definitions()? {
            match self.catalog.function(&definition.id) {
                Some(existing) if existing.owner_worker == engine_worker_id => {
                    if !same_meta_function_contract(existing, &definition) {
                        self.catalog.register_function(definition, None, false)?;
                    }
                }
                Some(existing) => {
                    return Err(EngineError::OwnerMismatch {
                        kind: "function",
                        id: existing.id.to_string(),
                        owner: existing.owner_worker.to_string(),
                        attempted_owner: engine_worker_id.to_string(),
                    });
                }
                None => {
                    self.catalog.register_function(definition, None, false)?;
                }
            }
        }
        self.bootstrap_primitive_capabilities()?;
        Ok(())
    }

    fn bootstrap_primitive_capabilities(&mut self) -> Result<()> {
        for worker in primitive_workers()? {
            let worker_id = worker.id.clone();
            match self.catalog.worker(&worker_id) {
                Some(existing)
                    if existing.kind == worker.kind
                        && existing.namespace_claims == worker.namespace_claims => {}
                Some(existing) => {
                    return Err(EngineError::PolicyViolation(format!(
                        "primitive namespace {} already claimed by incompatible worker {:?}",
                        worker_id, existing.kind
                    )));
                }
                None => {
                    self.catalog.register_worker(worker, false)?;
                }
            }
        }

        for registration in primitive_function_definitions(&self.primitives)? {
            let definition = registration.definition;
            let handler = registration.handler;
            match self.catalog.function(&definition.id) {
                Some(existing) if existing.owner_worker == definition.owner_worker => {
                    if !same_primitive_function_contract(existing, &definition) {
                        self.catalog.register_function(definition, handler, false)?;
                    }
                }
                Some(existing) => {
                    return Err(EngineError::OwnerMismatch {
                        kind: "function",
                        id: existing.id.to_string(),
                        owner: existing.owner_worker.to_string(),
                        attempted_owner: definition.owner_worker.to_string(),
                    });
                }
                None => {
                    self.catalog.register_function(definition, handler, false)?;
                }
            }
        }
        Ok(())
    }
}

fn same_primitive_function_contract(
    existing: &FunctionDefinition,
    expected: &FunctionDefinition,
) -> bool {
    existing.id == expected.id
        && existing.owner_worker == expected.owner_worker
        && existing.description == expected.description
        && existing.request_schema == expected.request_schema
        && existing.response_schema == expected.response_schema
        && existing.opaque_response == expected.opaque_response
        && existing.tags == expected.tags
        && existing.visibility == expected.visibility
        && existing.effect_class == expected.effect_class
        && existing.risk_level == expected.risk_level
        && existing.idempotency == expected.idempotency
        && existing.resource_lease == expected.resource_lease
        && existing.compensation == expected.compensation
        && existing.output_contract == expected.output_contract
        && existing.required_authority == expected.required_authority
        && existing.allowed_delivery_modes == expected.allowed_delivery_modes
        && existing.health == expected.health
        && existing.provenance == expected.provenance
        && existing.metadata == expected.metadata
}
