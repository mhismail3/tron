//! JSON-RPC protocol constants shared by canonical engine functions.
//!
//! Protocol-version checks are a transport concern. Keeping these constants in
//! the transport module prevents domain capabilities from depending on startup
//! or WebSocket framing code.

/// Current JSON-RPC wire-protocol version.
///
/// Bumped only on breaking changes; additive fields old clients can silently
/// ignore do not bump this.
pub const CURRENT_PROTOCOL_VERSION: u32 = 1;

/// Minimum `protocolVersion` the server will accept.
///
/// Engine-native clients can inspect/invoke `system::ping` to check this value.
pub const MIN_CLIENT_PROTOCOL_VERSION: u32 = 1;
