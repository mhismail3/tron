use std::collections::BTreeMap;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::Arc;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::shared::server::errors::CapabilityError;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DeviceTokenRecord {
    pub(crate) token_hash: String,
    pub(crate) token: String,
    pub(crate) environment: String,
    pub(crate) bundle_id: String,
    pub(crate) updated_at: String,
}

impl fmt::Debug for DeviceTokenRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DeviceTokenRecord")
            .field("token_hash", &"[redacted]")
            .field("token", &"[redacted]")
            .field("environment", &self.environment)
            .field("bundle_id", &self.bundle_id)
            .field("updated_at", &self.updated_at)
            .finish()
    }
}

pub(crate) trait DeviceTokenStore: Send + Sync + fmt::Debug {
    fn upsert(
        &self,
        record: DeviceTokenRecord,
    ) -> Result<Option<DeviceTokenRecord>, CapabilityError>;
    fn get(&self, token_hash: &str) -> Result<Option<DeviceTokenRecord>, CapabilityError>;
    fn remove(&self, token_hash: &str) -> Result<Option<DeviceTokenRecord>, CapabilityError>;
}

#[derive(Debug)]
pub(super) struct DisabledDeviceTokenStore;

impl DeviceTokenStore for DisabledDeviceTokenStore {
    fn upsert(
        &self,
        _record: DeviceTokenRecord,
    ) -> Result<Option<DeviceTokenRecord>, CapabilityError> {
        Err(CapabilityError::NotAvailable {
            message: "APNs token custody is disabled in this runtime".to_owned(),
        })
    }

    fn get(&self, _token_hash: &str) -> Result<Option<DeviceTokenRecord>, CapabilityError> {
        Ok(None)
    }

    fn remove(&self, _token_hash: &str) -> Result<Option<DeviceTokenRecord>, CapabilityError> {
        Ok(None)
    }
}

#[derive(Debug)]
pub(super) struct FileDeviceTokenStore {
    path: PathBuf,
    lock: Mutex<()>,
}

impl FileDeviceTokenStore {
    pub(super) fn new(path: PathBuf) -> Self {
        Self {
            path,
            lock: Mutex::new(()),
        }
    }

    fn read_records(&self) -> Result<BTreeMap<String, DeviceTokenRecord>, CapabilityError> {
        if !self.path.exists() {
            return Ok(BTreeMap::new());
        }
        let bytes = fs::read(&self.path).map_err(storage_error)?;
        serde_json::from_slice(&bytes).map_err(|error| CapabilityError::Internal {
            message: format!("private APNs token store is invalid: {error}"),
        })
    }

    fn write_records(
        &self,
        records: &BTreeMap<String, DeviceTokenRecord>,
    ) -> Result<(), CapabilityError> {
        let parent = self
            .path
            .parent()
            .ok_or_else(|| CapabilityError::Internal {
                message: "private APNs token store path has no parent".to_owned(),
            })?;
        fs::create_dir_all(parent).map_err(storage_error)?;
        set_private_directory_permissions(parent)?;

        let bytes = serde_json::to_vec(records).map_err(|error| CapabilityError::Internal {
            message: format!("serialize private APNs token store: {error}"),
        })?;
        let temporary = temporary_path(&self.path);
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(storage_error)?;
        set_private_file_permissions(&temporary)?;
        if let Err(error) = file.write_all(&bytes).and_then(|()| file.sync_all()) {
            let _ = fs::remove_file(&temporary);
            return Err(storage_error(error));
        }
        if let Err(error) = fs::rename(&temporary, &self.path) {
            let _ = fs::remove_file(&temporary);
            return Err(storage_error(error));
        }
        set_private_file_permissions(&self.path)
    }
}

impl DeviceTokenStore for FileDeviceTokenStore {
    fn upsert(
        &self,
        record: DeviceTokenRecord,
    ) -> Result<Option<DeviceTokenRecord>, CapabilityError> {
        let _guard = self.lock.lock().map_err(lock_error)?;
        let mut records = self.read_records()?;
        let previous = records.insert(record.token_hash.clone(), record);
        self.write_records(&records)?;
        Ok(previous)
    }

    fn get(&self, token_hash: &str) -> Result<Option<DeviceTokenRecord>, CapabilityError> {
        let _guard = self.lock.lock().map_err(lock_error)?;
        Ok(self.read_records()?.get(token_hash).cloned())
    }

    fn remove(&self, token_hash: &str) -> Result<Option<DeviceTokenRecord>, CapabilityError> {
        let _guard = self.lock.lock().map_err(lock_error)?;
        let mut records = self.read_records()?;
        let removed = records.remove(token_hash);
        if removed.is_some() {
            self.write_records(&records)?;
        }
        Ok(removed)
    }
}

#[cfg(test)]
#[derive(Debug, Default)]
pub(crate) struct MemoryDeviceTokenStore {
    records: Mutex<BTreeMap<String, DeviceTokenRecord>>,
}

#[cfg(test)]
impl MemoryDeviceTokenStore {
    pub(crate) fn shared() -> Arc<Self> {
        Arc::new(Self::default())
    }
}

#[cfg(test)]
impl DeviceTokenStore for MemoryDeviceTokenStore {
    fn upsert(
        &self,
        record: DeviceTokenRecord,
    ) -> Result<Option<DeviceTokenRecord>, CapabilityError> {
        Ok(self
            .records
            .lock()
            .map_err(lock_error)?
            .insert(record.token_hash.clone(), record))
    }

    fn get(&self, token_hash: &str) -> Result<Option<DeviceTokenRecord>, CapabilityError> {
        Ok(self
            .records
            .lock()
            .map_err(lock_error)?
            .get(token_hash)
            .cloned())
    }

    fn remove(&self, token_hash: &str) -> Result<Option<DeviceTokenRecord>, CapabilityError> {
        Ok(self.records.lock().map_err(lock_error)?.remove(token_hash))
    }
}

fn temporary_path(path: &Path) -> PathBuf {
    path.with_extension(format!("tmp-{}", uuid::Uuid::now_v7()))
}

fn storage_error(error: std::io::Error) -> CapabilityError {
    CapabilityError::Internal {
        message: format!("private APNs token store I/O failed: {error}"),
    }
}

fn lock_error<T>(error: std::sync::PoisonError<T>) -> CapabilityError {
    CapabilityError::Internal {
        message: format!("private APNs token store lock failed: {error}"),
    }
}

#[cfg(unix)]
fn set_private_directory_permissions(path: &Path) -> Result<(), CapabilityError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(storage_error)
}

#[cfg(not(unix))]
fn set_private_directory_permissions(_path: &Path) -> Result<(), CapabilityError> {
    Ok(())
}

#[cfg(unix)]
fn set_private_file_permissions(path: &Path) -> Result<(), CapabilityError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(storage_error)
}

#[cfg(not(unix))]
fn set_private_file_permissions(_path: &Path) -> Result<(), CapabilityError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(token: &str) -> DeviceTokenRecord {
        DeviceTokenRecord {
            token_hash: format!("hash-{token}"),
            token: token.to_owned(),
            environment: "development".to_owned(),
            bundle_id: "com.example.beta".to_owned(),
            updated_at: "2026-07-11T00:00:00Z".to_owned(),
        }
    }

    #[test]
    fn file_store_round_trips_and_removes_private_tokens() {
        let directory = tempfile::tempdir().expect("temp directory");
        let path = directory.path().join("private").join("tokens.json");
        let store = FileDeviceTokenStore::new(path.clone());
        let inserted = record("aabb");

        assert!(store.upsert(inserted.clone()).expect("insert").is_none());
        assert_eq!(
            store.get(&inserted.token_hash).expect("get").unwrap().token,
            "aabb"
        );
        assert!(
            store
                .remove(&inserted.token_hash)
                .expect("remove")
                .is_some()
        );
        assert!(
            store
                .get(&inserted.token_hash)
                .expect("get removed")
                .is_none()
        );

        let source = fs::read_to_string(path).expect("stored JSON");
        assert!(!source.contains("aabb"));
    }

    #[cfg(unix)]
    #[test]
    fn file_store_uses_private_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().expect("temp directory");
        let path = directory.path().join("private").join("tokens.json");
        let store = FileDeviceTokenStore::new(path.clone());
        store.upsert(record("ccdd")).expect("insert");

        assert_eq!(
            fs::metadata(&path)
                .expect("file metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(path.parent().unwrap())
                .expect("directory metadata")
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }
}
