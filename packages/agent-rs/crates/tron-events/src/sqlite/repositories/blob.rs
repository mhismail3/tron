//! Blob repository — content-addressable storage with SHA-256 dedup.
//!
//! Blobs store large content (tool outputs, file contents) separately from events.
//! Content is hashed with SHA-256 for deduplication — storing the same content twice
//! increments the reference count instead of creating a duplicate row.

use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::errors::Result;
use crate::sqlite::row_types::BlobRow;

/// Blob repository — stateless, every method takes `&Connection`.
pub struct BlobRepo;

/// Storage size summary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlobSizeInfo {
    /// Total original (uncompressed) bytes.
    pub original: i64,
    /// Total compressed bytes.
    pub compressed: i64,
}

impl BlobRepo {
    /// Store content, deduplicating by SHA-256 hash.
    ///
    /// If identical content already exists, increments the reference count
    /// and returns the existing blob ID. Otherwise creates a new blob.
    pub fn store(conn: &Connection, content: &[u8], mime_type: &str) -> Result<String> {
        let hash = hex_sha256(content);

        // Check for existing blob with same hash
        let existing: Option<String> = conn
            .query_row(
                "SELECT id FROM blobs WHERE hash = ?1",
                params![hash],
                |row| row.get(0),
            )
            .optional()?;

        if let Some(id) = existing {
            let _ = conn.execute(
                "UPDATE blobs SET ref_count = ref_count + 1 WHERE id = ?1",
                params![id],
            )?;
            return Ok(id);
        }

        let id = format!("blob_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let size = i64::try_from(content.len()).unwrap_or(i64::MAX);

        let _ = conn.execute(
            "INSERT INTO blobs (id, hash, content, mime_type, size_original, size_compressed, compression, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'none', ?7)",
            params![id, hash, content, mime_type, size, size, now],
        )?;

        Ok(id)
    }

    /// Get blob content by ID.
    pub fn get_content(conn: &Connection, blob_id: &str) -> Result<Option<Vec<u8>>> {
        let content: Option<Vec<u8>> = conn
            .query_row(
                "SELECT content FROM blobs WHERE id = ?1",
                params![blob_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(content)
    }

    /// Get full blob record by ID.
    pub fn get_by_id(conn: &Connection, blob_id: &str) -> Result<Option<BlobRow>> {
        let row = conn
            .query_row(
                "SELECT id, hash, content, mime_type, size_original, size_compressed, compression, created_at, ref_count
                 FROM blobs WHERE id = ?1",
                params![blob_id],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
    }

    /// Get blob by SHA-256 hash.
    pub fn get_by_hash(conn: &Connection, hash: &str) -> Result<Option<BlobRow>> {
        let row = conn
            .query_row(
                "SELECT id, hash, content, mime_type, size_original, size_compressed, compression, created_at, ref_count
                 FROM blobs WHERE hash = ?1",
                params![hash],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
    }

    /// Get reference count for a blob.
    pub fn get_ref_count(conn: &Connection, blob_id: &str) -> Result<Option<i64>> {
        let count: Option<i64> = conn
            .query_row(
                "SELECT ref_count FROM blobs WHERE id = ?1",
                params![blob_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(count)
    }

    /// Increment reference count.
    pub fn increment_ref_count(conn: &Connection, blob_id: &str) -> Result<bool> {
        let changed = conn.execute(
            "UPDATE blobs SET ref_count = ref_count + 1 WHERE id = ?1",
            params![blob_id],
        )?;
        Ok(changed > 0)
    }

    /// Decrement reference count (floor at 0). Returns new count if blob exists.
    pub fn decrement_ref_count(conn: &Connection, blob_id: &str) -> Result<Option<i64>> {
        let _ = conn.execute(
            "UPDATE blobs SET ref_count = ref_count - 1 WHERE id = ?1 AND ref_count > 0",
            params![blob_id],
        )?;
        Self::get_ref_count(conn, blob_id)
    }

    /// Delete all blobs with zero references. Returns count deleted.
    pub fn delete_unreferenced(conn: &Connection) -> Result<usize> {
        let changed = conn.execute("DELETE FROM blobs WHERE ref_count <= 0", [])?;
        Ok(changed)
    }

    /// Count total blobs.
    pub fn count(conn: &Connection) -> Result<i64> {
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))?;
        Ok(count)
    }

    /// Get total storage usage.
    pub fn get_total_size(conn: &Connection) -> Result<BlobSizeInfo> {
        let (original, compressed) = conn.query_row(
            "SELECT COALESCE(SUM(size_original), 0), COALESCE(SUM(size_compressed), 0) FROM blobs",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        Ok(BlobSizeInfo {
            original,
            compressed,
        })
    }

    fn map_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<BlobRow> {
        Ok(BlobRow {
            id: row.get(0)?,
            hash: row.get(1)?,
            content: row.get(2)?,
            mime_type: row.get(3)?,
            size_original: row.get(4)?,
            size_compressed: row.get(5)?,
            compression: row.get(6)?,
            created_at: row.get(7)?,
            ref_count: row.get(8)?,
        })
    }
}

fn hex_sha256(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    format!("{:x}", hasher.finalize())
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::sqlite::migrations::run_migrations;

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
            .unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    #[test]
    fn store_and_retrieve() {
        let conn = setup();
        let id = BlobRepo::store(&conn, b"hello world", "text/plain").unwrap();
        assert!(id.starts_with("blob_"));

        let content = BlobRepo::get_content(&conn, &id).unwrap().unwrap();
        assert_eq!(content, b"hello world");
    }

    #[test]
    fn store_deduplicates() {
        let conn = setup();
        let id1 = BlobRepo::store(&conn, b"same content", "text/plain").unwrap();
        let id2 = BlobRepo::store(&conn, b"same content", "text/plain").unwrap();
        assert_eq!(id1, id2);

        // Ref count should be 2
        let count = BlobRepo::get_ref_count(&conn, &id1).unwrap().unwrap();
        assert_eq!(count, 2);
    }

    #[test]
    fn store_different_content_creates_new() {
        let conn = setup();
        let id1 = BlobRepo::store(&conn, b"content a", "text/plain").unwrap();
        let id2 = BlobRepo::store(&conn, b"content b", "text/plain").unwrap();
        assert_ne!(id1, id2);
    }

    #[test]
    fn get_by_id_full_record() {
        let conn = setup();
        let id = BlobRepo::store(&conn, b"test data", "text/plain").unwrap();

        let blob = BlobRepo::get_by_id(&conn, &id).unwrap().unwrap();
        assert_eq!(blob.id, id);
        assert_eq!(blob.content, b"test data");
        assert_eq!(blob.mime_type, "text/plain");
        assert_eq!(blob.size_original, 9);
        assert_eq!(blob.compression, "none");
        assert_eq!(blob.ref_count, 1);
    }

    #[test]
    fn get_by_hash() {
        let conn = setup();
        let id = BlobRepo::store(&conn, b"find by hash", "text/plain").unwrap();
        let hash = hex_sha256(b"find by hash");

        let blob = BlobRepo::get_by_hash(&conn, &hash).unwrap().unwrap();
        assert_eq!(blob.id, id);
    }

    #[test]
    fn get_content_not_found() {
        let conn = setup();
        let content = BlobRepo::get_content(&conn, "blob_nonexistent").unwrap();
        assert!(content.is_none());
    }

    #[test]
    fn increment_ref_count() {
        let conn = setup();
        let id = BlobRepo::store(&conn, b"data", "text/plain").unwrap();
        assert_eq!(BlobRepo::get_ref_count(&conn, &id).unwrap().unwrap(), 1);

        BlobRepo::increment_ref_count(&conn, &id).unwrap();
        assert_eq!(BlobRepo::get_ref_count(&conn, &id).unwrap().unwrap(), 2);
    }

    #[test]
    fn decrement_ref_count() {
        let conn = setup();
        let id = BlobRepo::store(&conn, b"data", "text/plain").unwrap();

        let new_count = BlobRepo::decrement_ref_count(&conn, &id).unwrap().unwrap();
        assert_eq!(new_count, 0);
    }

    #[test]
    fn decrement_ref_count_floors_at_zero() {
        let conn = setup();
        let id = BlobRepo::store(&conn, b"data", "text/plain").unwrap();

        BlobRepo::decrement_ref_count(&conn, &id).unwrap(); // 1 -> 0
        BlobRepo::decrement_ref_count(&conn, &id).unwrap(); // stays 0
        assert_eq!(BlobRepo::get_ref_count(&conn, &id).unwrap().unwrap(), 0);
    }

    #[test]
    fn delete_unreferenced() {
        let conn = setup();
        let id1 = BlobRepo::store(&conn, b"keep me", "text/plain").unwrap();
        let id2 = BlobRepo::store(&conn, b"delete me", "text/plain").unwrap();

        BlobRepo::decrement_ref_count(&conn, &id2).unwrap(); // ref_count = 0

        let deleted = BlobRepo::delete_unreferenced(&conn).unwrap();
        assert_eq!(deleted, 1);

        assert!(BlobRepo::get_by_id(&conn, &id1).unwrap().is_some());
        assert!(BlobRepo::get_by_id(&conn, &id2).unwrap().is_none());
    }

    #[test]
    fn count_blobs() {
        let conn = setup();
        assert_eq!(BlobRepo::count(&conn).unwrap(), 0);

        BlobRepo::store(&conn, b"a", "text/plain").unwrap();
        BlobRepo::store(&conn, b"b", "text/plain").unwrap();
        assert_eq!(BlobRepo::count(&conn).unwrap(), 2);

        // Duplicate doesn't increase count
        BlobRepo::store(&conn, b"a", "text/plain").unwrap();
        assert_eq!(BlobRepo::count(&conn).unwrap(), 2);
    }

    #[test]
    fn get_total_size_empty() {
        let conn = setup();
        let size = BlobRepo::get_total_size(&conn).unwrap();
        assert_eq!(
            size,
            BlobSizeInfo {
                original: 0,
                compressed: 0
            }
        );
    }

    #[test]
    fn get_total_size() {
        let conn = setup();
        BlobRepo::store(&conn, b"12345", "text/plain").unwrap(); // 5 bytes
        BlobRepo::store(&conn, b"1234567890", "text/plain").unwrap(); // 10 bytes

        let size = BlobRepo::get_total_size(&conn).unwrap();
        assert_eq!(size.original, 15);
        assert_eq!(size.compressed, 15); // no compression
    }

    #[test]
    fn binary_content() {
        let conn = setup();
        let binary = vec![0u8, 1, 2, 255, 254, 253];
        let id = BlobRepo::store(&conn, &binary, "application/octet-stream").unwrap();

        let content = BlobRepo::get_content(&conn, &id).unwrap().unwrap();
        assert_eq!(content, binary);
    }

    #[test]
    fn sha256_deterministic() {
        assert_eq!(hex_sha256(b"hello"), hex_sha256(b"hello"));
        assert_ne!(hex_sha256(b"hello"), hex_sha256(b"world"));
    }
}
