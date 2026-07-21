//! Named-vault secret loading plus bundle and invocation leak admission checks.

use super::*;

impl WorkerRuntime {
    pub(super) fn load_secrets(
        &self,
        bundle: &WorkerBundle,
    ) -> Result<HashMap<String, String>, String> {
        let vault = self
            .store
            .home()
            .join(crate::shared::foundation::paths::dirs::WORKSPACE)
            .join(crate::shared::foundation::paths::dirs::VAULT);
        let mut secrets = HashMap::new();
        for binding in &bundle.secret_bindings {
            let name = binding.name();
            let direct = vault.join(name);
            let json_path = vault.join(format!("{name}.json"));
            let path = if direct.is_file() {
                direct
            } else if json_path.is_file() {
                json_path
            } else {
                if binding.required() {
                    return Err(format!(
                        "required named secret binding '{name}' was not found"
                    ));
                }
                continue;
            };
            let value = std::fs::read_to_string(&path)
                .map_err(|error| format!("read named secret binding '{name}': {error}"))?;
            let _ = secrets.insert(name.to_owned(), value.trim_end().to_owned());
        }
        Ok(secrets)
    }

    pub(super) fn reject_secret_material_in_bundle(
        &self,
        bundle: &WorkerBundle,
    ) -> Result<(), String> {
        let secrets = self.load_all_vault_secrets()?;
        if secrets.is_empty() {
            return Ok(());
        }
        let encoded = serde_json::to_string(bundle)
            .map_err(|error| format!("encode worker bundle for secret scan: {error}"))?;
        for (name, secret) in secrets {
            if secret.len() >= 4 && encoded.contains(&secret) {
                return Err(format!(
                    "worker bundle contains the value of named secret '{name}'; keep only the logical binding name"
                ));
            }
        }
        Ok(())
    }

    pub(super) fn reject_secret_material_in_value(
        &self,
        value: &Value,
        surface: &str,
    ) -> Result<(), String> {
        let secrets = self.load_all_vault_secrets()?;
        if secrets.is_empty() {
            return Ok(());
        }
        let encoded = serde_json::to_string(value)
            .map_err(|error| format!("encode {surface} for secret scan: {error}"))?;
        for (name, secret) in secrets {
            if secret.len() >= 4 && encoded.contains(&secret) {
                return Err(format!(
                    "{surface} contains the value of vault secret '{name}'; workers receive secrets only through declared logical bindings"
                ));
            }
        }
        Ok(())
    }

    pub(super) fn load_all_vault_secrets(&self) -> Result<HashMap<String, String>, String> {
        let vault = self
            .store
            .home()
            .join(crate::shared::foundation::paths::dirs::WORKSPACE)
            .join(crate::shared::foundation::paths::dirs::VAULT);
        if !vault.is_dir() {
            return Ok(HashMap::new());
        }
        let mut secrets = HashMap::new();
        for entry in walkdir::WalkDir::new(&vault).follow_links(false) {
            let entry = entry.map_err(|error| format!("scan named-secret vault: {error}"))?;
            if !entry.file_type().is_file() {
                continue;
            }
            let relative = entry
                .path()
                .strip_prefix(&vault)
                .map_err(|error| error.to_string())?
                .display()
                .to_string();
            let value = std::fs::read_to_string(entry.path())
                .map_err(|error| format!("read named-secret vault entry '{relative}': {error}"))?;
            let value = value.trim_end().to_owned();
            if !value.is_empty() {
                let _ = secrets.insert(relative, value);
            }
        }
        Ok(secrets)
    }
}
