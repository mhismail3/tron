//! Cross-domain server helpers.
//!
//! Shared modules are deliberately small and transport-neutral. They provide
//! server tool context, neutral event payloads, and test construction
//! utilities used by multiple domain workers. Executable behavior belongs in
//! `domains`; protocol parsing stays in the client protocol layer.
//! Agent-loop test hosts install the canonical internal Team Context contract,
//! so isolated turns retain the same mandatory provider boundary as production.

pub mod context;
pub(crate) mod error_mapping;
pub(crate) mod errors;
pub(crate) mod events;
pub(crate) mod failure;
pub(crate) mod params;
pub(crate) mod protocol;
#[cfg(test)]
pub(crate) mod test_support;
pub(crate) mod validation;
