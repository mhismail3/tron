//! Canonical function inventory for the filesystem domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "filesystem::list_dir",
    "filesystem::get_home",
    "filesystem::create_dir",
    "filesystem::read_file",
];
