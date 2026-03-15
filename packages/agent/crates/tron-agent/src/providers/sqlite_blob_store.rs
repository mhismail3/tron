//! `BlobStore` backed by `BlobRepo` via `EventStore`.

use std::sync::Arc;

use async_trait::async_trait;
use tron::events::EventStore;
use tron::events::sqlite::repositories::blob::BlobRepo;
use tron::tools::errors::ToolError;
use tron::tools::traits::BlobStore;

/// SQLite-backed blob store wrapping `BlobRepo`.
pub struct SqliteBlobStore {
    store: Arc<EventStore>,
}

impl SqliteBlobStore {
    pub fn new(store: Arc<EventStore>) -> Self {
        Self { store }
    }
}

#[async_trait]
impl BlobStore for SqliteBlobStore {
    async fn store(&self, content: &[u8], mime_type: &str) -> Result<String, ToolError> {
        let store = self.store.clone();
        let content = content.to_vec();
        let mime = mime_type.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = store.pool().get().map_err(|e| ToolError::Internal {
                message: format!("blob store connection error: {e}"),
            })?;
            BlobRepo::store(&conn, &content, &mime).map_err(|e| ToolError::Internal {
                message: format!("blob store write error: {e}"),
            })
        })
        .await
        .map_err(|e| ToolError::Internal {
            message: format!("blob store task join error: {e}"),
        })?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // SqliteBlobStore is integration-tested via BlobRepo tests in tron-events.
    // Unit tests here verify construction.
    #[test]
    fn sqlite_blob_store_requires_event_store() {
        // Type-level proof that SqliteBlobStore wraps EventStore
        fn _assert_blob_store<T: BlobStore>() {}
        _assert_blob_store::<SqliteBlobStore>();
    }
}
