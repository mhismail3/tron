use crate::domains::session::event_store::errors::Result;
use crate::domains::session::event_store::sqlite::repositories::blob::BlobRepo;
use crate::domains::session::event_store::sqlite::repositories::workspace::WorkspaceRepo;
use crate::domains::session::event_store::{BlobRow, WorkspaceRow};

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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_store_stores_blob_content() {
        let pool = crate::domains::session::event_store::sqlite::connection::new_in_memory(
            &crate::domains::session::event_store::sqlite::connection::ConnectionConfig::default(),
        )
        .expect("pool");
        let store = EventStore::new(pool);
        let conn = store.conn().expect("conn");
        crate::domains::session::event_store::sqlite::migrations::run_migrations(&conn)
            .expect("migrate");
        let blob_id = store
            .store_blob(b"hello", "text/plain")
            .expect("store blob");
        let content = store
            .get_blob_content(&blob_id)
            .expect("read blob")
            .expect("blob content");
        assert_eq!(content, b"hello");
    }
}
