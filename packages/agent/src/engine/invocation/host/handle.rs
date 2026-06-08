//! Engine host handle constructors and narrow test/bootstrap locking.

use super::*;

impl EngineHostHandle {
    /// Create an in-memory engine host for tests and isolated runtime services.
    pub fn new_in_memory() -> Result<Self> {
        Ok(Self::from_host(EngineHost::new()?))
    }

    /// Open a SQLite-backed engine host.
    pub fn open_sqlite(path: impl AsRef<Path>) -> Result<Self> {
        Ok(Self::from_host(EngineHost::open_sqlite(path)?))
    }

    /// Wrap an initialized host.
    #[must_use]
    fn from_host(host: EngineHost) -> Self {
        let stores = host.primitives.clone();
        let handle = Self::from_inner(Arc::new(Mutex::new(host)));
        stores
            .install_engine_host(Arc::downgrade(&handle.inner))
            .expect("engine host handle is installed exactly once");
        handle
    }

    pub(in crate::engine) fn from_inner(inner: Arc<Mutex<EngineHost>>) -> Self {
        Self { inner }
    }

    /// Lock the host for deep test inspection or narrow bootstrap setup.
    ///
    /// Production invocation/discovery paths should use the intent-shaped
    /// methods on this handle so they do not hold the host mutex across handler
    /// execution.
    pub async fn lock(&self) -> MutexGuard<'_, EngineHost> {
        self.inner.lock().await
    }
}
