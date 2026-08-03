//! Engine host handle constructors and test-only deep inspection.

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
        Self::from_inner(Arc::new(Mutex::new(host)))
    }

    pub(in crate::engine) fn from_inner(inner: Arc<Mutex<EngineHost>>) -> Self {
        Self { inner }
    }

    /// Lock the host for deep unit-test inspection.
    #[cfg(test)]
    pub(crate) async fn lock(&self) -> tokio::sync::MutexGuard<'_, EngineHost> {
        self.inner.lock().await
    }
}
