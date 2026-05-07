//! Public engine transport protocol constants.
//!
//! The current public transport is JSON-RPC, but these values describe the
//! engine transport contract exposed by `engine.*` methods rather than any
//! domain capability implementation.

/// Current public engine transport protocol version.
///
/// Bumped only on breaking changes; additive fields old clients can silently
/// ignore do not bump this.
pub const CURRENT_PROTOCOL_VERSION: u32 = 1;

/// Minimum public engine transport protocol version the server will accept.
pub const MIN_CLIENT_PROTOCOL_VERSION: u32 = 1;
