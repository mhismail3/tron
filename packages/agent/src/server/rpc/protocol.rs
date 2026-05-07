//! JSON-RPC protocol constants shared by canonical engine functions.
//!
//! Protocol compatibility is a transport concern. Keeping these constants out
//! of handler fixtures prevents old RPC handler modules from remaining a
//! production dependency.

/// Current RPC wire-protocol version.
///
/// Bumped only on breaking changes; additive fields old clients can silently
/// ignore do not bump this.
pub const CURRENT_PROTOCOL_VERSION: u32 = 1;

/// Minimum `protocolVersion` the server will accept.
///
/// Every supported client must send this field in `system.ping`; missing or
/// malformed values are rejected as invalid params instead of being treated as
/// an older client.
pub const MIN_CLIENT_PROTOCOL_VERSION: u32 = 1;
