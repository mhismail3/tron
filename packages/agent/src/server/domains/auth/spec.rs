//! Canonical function inventory for the auth domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "auth::get",
    "auth::update",
    "auth::clear",
    "auth::oauth_begin",
    "auth::oauth_complete",
    "auth::rename_account",
    "auth::set_active",
    "auth::remove_account",
    "auth::remove_api_key",
];
