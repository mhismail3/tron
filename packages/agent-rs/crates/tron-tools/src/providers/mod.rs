//! Production and stub implementations of the DI traits.
//!
//! Real providers are used for tools with full backend support.
//! Stub providers are used for tools whose backends aren't yet wired,
//! allowing them to appear in the tool registry while returning
//! "not available" errors at execution time.

pub mod filesystem;
pub mod http;
pub mod process;
pub mod stubs;

pub use filesystem::RealFileSystem;
pub use http::ReqwestHttpClient;
pub use process::TokioProcessRunner;
pub use stubs::{
    StubBrowserDelegate, StubEventStoreQuery, StubMessageBus, StubNotifyDelegate,
    StubSubagentSpawner, StubTaskManagerDelegate,
};
