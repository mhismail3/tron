//! Test-only store construction that bypasses snapshot policy.

use super::*;

impl WorkerStore {
    pub fn open_without_snapshot(home: PathBuf) -> Result<Self, String> {
        let root = home
            .join(crate::shared::foundation::paths::dirs::WORKSPACE)
            .join(crate::shared::foundation::paths::dirs::WORKERS);
        let state_root = home
            .join(crate::shared::foundation::paths::dirs::WORKSPACE)
            .join(crate::shared::foundation::paths::dirs::WORKER_STATE);
        let database = home
            .join(crate::shared::foundation::paths::dirs::INTERNAL)
            .join(crate::shared::foundation::paths::dirs::DB)
            .join("workers.sqlite");
        fs::create_dir_all(&root).map_err(|error| error.to_string())?;
        crate::shared::foundation::home::set_private_directory_permissions(&root)
            .map_err(|error| error.to_string())?;
        fs::create_dir_all(&state_root).map_err(|error| error.to_string())?;
        crate::shared::foundation::home::set_private_directory_permissions(&state_root)
            .map_err(|error| error.to_string())?;
        if let Some(parent) = database.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            crate::shared::foundation::home::set_private_directory_permissions(parent)
                .map_err(|error| error.to_string())?;
        }
        let store = Self {
            home,
            root,
            state_root,
            database,
        };
        store.initialize()?;
        Ok(store)
    }
}
