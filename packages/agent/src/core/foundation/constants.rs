//! Package-level constants.

/// Current version of the Tron agent (sourced from Cargo.toml).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Package name.
pub const NAME: &str = "tron";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_semver() {
        let parts: Vec<&str> = VERSION.split('.').collect();
        assert_eq!(parts.len(), 3, "VERSION must be semver (MAJOR.MINOR.PATCH)");
        for part in parts {
            let _: u32 = part.parse().expect("each semver segment must be a number");
        }
    }

    #[test]
    fn version_matches_cargo_toml() {
        assert_eq!(VERSION, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn name_is_lowercase() {
        assert_eq!(NAME, NAME.to_lowercase());
    }
}
