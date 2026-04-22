use crate::events::errors::Result;
use crate::events::sqlite::repositories::blob::BlobRepo;
use crate::events::sqlite::repositories::device_token::{DeviceTokenRepo, RegisterTokenResult};
use crate::events::sqlite::repositories::workspace::WorkspaceRepo;
use crate::events::sqlite::row_types::{BlobRow, DeviceTokenRow, WorkspaceRow};

use super::EventStore;

impl EventStore {
    /// Get workspace by path.
    pub fn get_workspace_by_path(&self, path: &str) -> Result<Option<WorkspaceRow>> {
        let conn = self.conn()?;
        WorkspaceRepo::get_by_path(&conn, path)
    }

    /// Find all workspaces whose path matches the given prefix (exact + children).
    pub fn find_workspaces_by_path_prefix(&self, prefix: &str) -> Result<Vec<WorkspaceRow>> {
        let conn = self.conn()?;
        WorkspaceRepo::find_by_path_prefix(&conn, prefix)
    }

    /// Get or create workspace by path.
    pub fn get_or_create_workspace(&self, path: &str, name: Option<&str>) -> Result<WorkspaceRow> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            WorkspaceRepo::get_or_create(&conn, path, name)
        })
    }

    /// List all workspaces.
    pub fn list_workspaces(&self) -> Result<Vec<WorkspaceRow>> {
        let conn = self.conn()?;
        WorkspaceRepo::list(&conn)
    }

    /// Store blob content (SHA-256 deduplicated).
    pub fn store_blob(&self, content: &[u8], mime_type: &str) -> Result<String> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            BlobRepo::store(&conn, content, mime_type)
        })
    }

    /// Get blob content by ID.
    pub fn get_blob_content(&self, blob_id: &str) -> Result<Option<Vec<u8>>> {
        let conn = self.conn()?;
        BlobRepo::get_content(&conn, blob_id)
    }

    /// Get full blob metadata.
    pub fn get_blob(&self, blob_id: &str) -> Result<Option<BlobRow>> {
        let conn = self.conn()?;
        BlobRepo::get_by_id(&conn, blob_id)
    }

    /// Register or update a device token. Returns `{id, created}`.
    ///
    /// `bundle_id` is the APNs topic the token was issued against and is
    /// used as the `apns-topic` header at send time. Every client sends
    /// its bundle identifier on registration — the `device_tokens`
    /// column is NOT NULL since the v001 consolidated schema, so there
    /// is no fallback path.
    pub fn register_device_token(
        &self,
        device_token: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
        environment: &str,
        bundle_id: &str,
    ) -> Result<RegisterTokenResult> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            DeviceTokenRepo::register(
                &conn,
                device_token,
                session_id,
                workspace_id,
                environment,
                bundle_id,
            )
        })
    }

    /// Unregister (deactivate) a device token.
    pub fn unregister_device_token(&self, device_token: &str) -> Result<bool> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            DeviceTokenRepo::unregister(&conn, device_token)
        })
    }

    /// Get all active device tokens.
    pub fn get_all_active_device_tokens(&self) -> Result<Vec<DeviceTokenRow>> {
        let conn = self.conn()?;
        DeviceTokenRepo::get_all_active(&conn)
    }
}

#[async_trait::async_trait]
impl crate::tools::traits::BlobStore for EventStore {
    async fn store(
        &self,
        content: &[u8],
        mime_type: &str,
    ) -> std::result::Result<String, crate::tools::errors::ToolError> {
        let pool = self.pool().clone();
        let content = content.to_vec();
        let mime = mime_type.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = pool.get().map_err(|e| {
                crate::tools::errors::ToolError::Internal {
                    message: format!("blob store connection error: {e}"),
                }
            })?;
            BlobRepo::store(&conn, &content, &mime).map_err(|e| {
                crate::tools::errors::ToolError::Internal {
                    message: format!("blob store write error: {e}"),
                }
            })
        })
        .await
        .map_err(|e| crate::tools::errors::ToolError::Internal {
            message: format!("blob store task join error: {e}"),
        })?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_store_implements_blob_store() {
        fn assert_blob_store<T: crate::tools::traits::BlobStore>() {}
        assert_blob_store::<EventStore>();
    }
}
