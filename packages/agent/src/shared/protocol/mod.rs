//! Cross-owner protocol DTOs and message models.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`content`] | User/assistant content block DTOs |
//! | [`document_extractor`] | Document text extraction helpers for protocol content |
//! | [`events`] | Runtime event payloads and stream event DTOs |
//! | [`memory`] | Source-backed memory contract DTOs: policy, records, prompt traces, evals, and migration |
//! | [`messages`] | Chat message DTOs |
//! | [`model_audit`] | Provider request audit and metadata-only reasoning/status evidence DTOs consumed by replay manifests; redacted and bounded before persistence |
//! | [`model_capabilities`] | Model-facing capability result DTOs |

pub mod content;
pub mod document_extractor;
pub mod events;
pub mod memory;
pub mod messages;
pub mod model_audit;
pub mod model_capabilities;
