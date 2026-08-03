//! Provider protocol boundary for model-native wire concepts.
//!
//! Provider APIs still speak in their own stream/block vocabularies. This
//! module is the only shared place where Tron keeps provider-native tool
//! invocation argument parsing and provider-specific invocation id remapping.
//! Code outside provider modules should consume canonical tool
//! invocation/history structs, not provider wire shapes. Malformed provider
//! argument payloads fail closed here before a canonical tool invocation
//! can be recorded or executed.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `tool_parsing` | Fail-closed JSON parsing for streamed provider invocation arguments |
//! | `id_remapping` | Provider-specific invocation id format conversion at prompt serialization time |
//!
//! # INVARIANT: provider protocol terms stay at the boundary
//!
//! Provider-native ids and argument fragments are converted before entering the
//! runner, session ledger, registry, audit, or iOS DTO layers. Completed
//! tool invocation arguments must be absent, empty, or a JSON object;
//! malformed and non-object payloads surface as provider stream errors.

pub mod id_remapping;
pub mod tool_parsing;

pub use id_remapping::{IdFormat, build_invocation_id_mapping, remap_invocation_id};
pub use tool_parsing::{
    ToolArgumentParseError, ToolCallContext, is_valid_tool_call_arguments,
    parse_tool_call_arguments,
};
