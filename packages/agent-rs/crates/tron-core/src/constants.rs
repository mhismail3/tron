//! Package-level constants.

/// Current version of the Tron agent.
pub const VERSION: &str = "0.1.0";

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
    fn name_is_lowercase() {
        assert_eq!(NAME, NAME.to_lowercase());
    }
}
