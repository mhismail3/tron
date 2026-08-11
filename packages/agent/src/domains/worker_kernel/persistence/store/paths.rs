//! Profile-owned worker home and persistent-state paths.

use std::path::Path;

use super::*;

impl WorkerStore {
    pub fn home(&self) -> &Path {
        &self.home
    }

    pub fn state_dir(&self, worker_id: &str) -> Result<PathBuf, String> {
        validate_identifier(worker_id, "workerId")?;
        let path = self.state_root.join(worker_id);
        fs::create_dir_all(&path)
            .map_err(|error| format!("create worker state directory: {error}"))?;
        crate::shared::foundation::home::set_private_directory_permissions(&path)
            .map_err(|error| format!("secure worker state directory: {error}"))?;
        Ok(path)
    }
}
