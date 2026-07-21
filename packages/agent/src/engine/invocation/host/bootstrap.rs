//! Host construction and built-in capability registration.

use super::*;

impl EngineHost {
    /// Create a host with an in-memory engine ledger.
    pub(in crate::engine) fn new() -> Result<Self> {
        Self::from_catalog_and_primitives(LiveCatalog::new(), PrimitiveStores::in_memory())
    }

    /// Create a host with a caller-supplied ledger.
    #[cfg(test)]
    pub(in crate::engine) fn with_ledger_store(ledger: Box<dyn EngineLedgerStore>) -> Result<Self> {
        Self::from_catalog_and_primitives(
            LiveCatalog::with_ledger_store(ledger),
            PrimitiveStores::in_memory(),
        )
    }

    /// Open a host whose ledger and primitive stores share one SQLite file.
    pub(in crate::engine) fn open_sqlite(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let storage_runtime = crate::shared::storage::StorageRuntime::new(path.to_path_buf());
        storage_runtime
            .prepare_for_startup()
            .map_err(storage_error)?;
        drop(storage_runtime.open_connection().map_err(storage_error)?);
        let _startup_checkpoint = storage_runtime.checkpoint().map_err(storage_error)?;
        let ledger = SqliteEngineLedgerStore::open(path)?;
        let mut catalog = LiveCatalog::with_ledger_store(Box::new(ledger));
        catalog.hydrate_catalog_revision_from_ledger()?;
        let mut host = Self::from_catalog_and_primitives(catalog, PrimitiveStores::sqlite(path)?)?;
        host.storage_path = Some(path.to_path_buf());
        Ok(host)
    }

    fn from_catalog_and_primitives(
        catalog: LiveCatalog,
        primitives: PrimitiveStores,
    ) -> Result<Self> {
        let host = Self {
            catalog,
            primitives,
            storage_path: None,
        };
        Ok(host)
    }
}
