//! agent-browser provider — CLI-based browser automation via Vercel's agent-browser.

pub mod adapter;
pub mod cli;
pub mod error;
pub mod refs;
pub mod stream;

pub use adapter::AgentBrowserProvider;
