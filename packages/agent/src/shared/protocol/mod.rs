//! Cross-owner protocol DTOs and message models.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`content`] | User/assistant content block DTOs |
//! | [`document_extractor`] | Document text extraction helpers for protocol content |
//! | [`events`] | Runtime event payloads and stream event DTOs |
//! | [`memory`] | Session memory DTOs |
//! | [`messages`] | Chat message DTOs |
//! | [`model_capabilities`] | Model-facing capability result DTOs |

pub mod content;
pub mod document_extractor;
pub mod events;
pub mod memory;
pub mod messages;
pub mod model_capabilities;
