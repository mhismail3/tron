//! Canonical function inventory for the import domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "import::list_sources",
    "import::list_sessions",
    "import::preview_session",
    "import::execute",
];
