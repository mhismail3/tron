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
        let (base, prerelease) = VERSION
            .split_once('-')
            .map_or((VERSION, None), |(base, pre)| (base, Some(pre)));
        let parts: Vec<&str> = base.split('.').collect();
        assert_eq!(parts.len(), 3, "VERSION must be semver (MAJOR.MINOR.PATCH)");
        for part in parts {
            let _: u32 = part.parse().expect("each semver segment must be a number");
        }
        if let Some(pre) = prerelease {
            let beta = pre
                .strip_prefix("beta.")
                .expect("only beta.N prereleases are supported");
            let parsed: u32 = beta.parse().expect("beta prerelease must be numeric");
            assert!(parsed > 0, "beta prerelease must be positive");
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
