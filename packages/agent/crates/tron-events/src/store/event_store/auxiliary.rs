use crate::errors::Result;
use crate::sqlite::repositories::blob::BlobRepo;
use crate::sqlite::repositories::device_token::{DeviceTokenRepo, RegisterTokenResult};
use crate::sqlite::repositories::workspace::WorkspaceRepo;
use crate::sqlite::row_types::{BlobRow, DeviceTokenRow, WorkspaceRow};

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
    pub fn register_device_token(
        &self,
        device_token: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
        environment: &str,
    ) -> Result<RegisterTokenResult> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            DeviceTokenRepo::register(&conn, device_token, session_id, workspace_id, environment)
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

    /// Mark a device token as invalid (e.g., after APNS 410 response).
    pub fn mark_device_token_invalid(&self, device_token: &str) -> Result<bool> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            DeviceTokenRepo::mark_invalid(&conn, device_token)
        })
    }
}
