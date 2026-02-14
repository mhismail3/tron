//! Real filesystem implementation using `tokio::fs`.

use std::io;
use std::path::Path;

use async_trait::async_trait;

use crate::traits::FileSystemOps;

/// Real filesystem operations backed by `tokio::fs`.
pub struct RealFileSystem;

#[async_trait]
impl FileSystemOps for RealFileSystem {
    async fn read_file(&self, path: &Path) -> Result<Vec<u8>, io::Error> {
        tokio::fs::read(path).await
    }

    async fn write_file(&self, path: &Path, content: &[u8]) -> Result<(), io::Error> {
        tokio::fs::write(path, content).await
    }

    async fn metadata(&self, path: &Path) -> Result<std::fs::Metadata, io::Error> {
        tokio::fs::metadata(path).await
    }

    async fn create_dir_all(&self, path: &Path) -> Result<(), io::Error> {
        tokio::fs::create_dir_all(path).await
    }

    fn exists(&self, path: &Path) -> bool {
        path.exists()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn read_nonexistent_returns_error() {
        let fs = RealFileSystem;
        let result = fs.read_file(Path::new("/tmp/nonexistent_tron_test_file")).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn write_and_read_roundtrip() {
        let fs = RealFileSystem;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.txt");

        fs.write_file(&path, b"hello world").await.unwrap();
        let content = fs.read_file(&path).await.unwrap();
        assert_eq!(content, b"hello world");
    }

    #[tokio::test]
    async fn metadata_returns_file_info() {
        let fs = RealFileSystem;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("meta.txt");
        fs.write_file(&path, b"data").await.unwrap();

        let meta = fs.metadata(&path).await.unwrap();
        assert_eq!(meta.len(), 4);
        assert!(meta.is_file());
    }

    #[tokio::test]
    async fn create_dir_all_nested() {
        let fs = RealFileSystem;
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("a").join("b").join("c");

        fs.create_dir_all(&nested).await.unwrap();
        assert!(nested.exists());
    }

    #[test]
    fn exists_checks_path() {
        let fs = RealFileSystem;
        assert!(fs.exists(Path::new("/tmp")));
        assert!(!fs.exists(Path::new("/tmp/nonexistent_tron_test_path")));
    }
}
