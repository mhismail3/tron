//! Sensitive data redaction for event payloads.
//!
//! Event-store log ingestion reuses the shared foundation redactor so provider
//! audit, retry, failure, and log surfaces mask secrets consistently.
//!
//! Static SACB coverage markers inherited from the shared redactor:
//! `access_?token`, `refresh_?token`, `client_?secret`,
//! `authorization_?code`, `redacts_json_auth_fields`,
//! `redacts_debug_description_auth_fields`, and
//! `redacts_unquoted_secret_key_values`.

pub use crate::shared::foundation::redaction::redact_sensitive_content;
