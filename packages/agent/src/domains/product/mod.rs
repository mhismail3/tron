//! Fixed authenticated product operations used by iOS and Mac clients.
//!
//! These functions are not model tools and are not adaptive behavior. They
//! preserve the stable public wire namespaces consumed by clients while
//! sharing the engine's typed registration and authenticated transport.
//!
//! | Module | Product responsibility |
//! |--------|------------------------|
//! | `blob` | Read event-store attachments |
//! | `logs` | Ingest and inspect bounded client diagnostics |
//! | `message` | Delete a durable conversation message |
//! | `system` | Pairing compatibility and server status |

pub(crate) mod blob;
pub(crate) mod logs;
pub(crate) mod message;
pub(crate) mod system;
