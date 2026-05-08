//! Tool operation implementations.
//!
//! The tools worker owns built-in tool function execution and live catalog
//! metadata for model-visible tools. Provider tool calls must resolve through
//! the engine catalog and enter the matching canonical `tool::*` function.
